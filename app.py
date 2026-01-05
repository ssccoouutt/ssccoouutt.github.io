import os
import json
import logging
import threading
import urllib.parse
import uuid
import time
from flask import Flask, request, jsonify, redirect, session, send_from_directory
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# --- CONFIGURATION ---
FRONTEND_URL = "https://techzonex.store/drive"
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"

# Hardcoded Automation IDs
UNPOSTED_FOLDER_ID = "14tf687_8F4o2oYJTqyCZmvJjq45jRliy"
SECOND_SOURCE_FOLDER_ID = "12V7EnRIYcSgEtt0PR5fhV8cO22nzYuiv"

RAW_CREDENTIALS = {
    "web": {
        "client_id": "704057951722-i19ln87gtlofufuet9okb9mvdj9t9hel.apps.googleusercontent.com",
        "project_id": "teledrive-pro",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
        "client_secret": "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",
        "redirect_uris": [f"{SERVER_DOMAIN}/callback"],
        "javascript_origins": [SERVER_DOMAIN, "https://techzonex.store"]
    }
}

os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]

app = Flask(__name__)
app.secret_key = os.urandom(24)
CORS(app)

TASKS = {}

MIME_MAP = {
    'application/pdf': 'PDF',
    'image/': 'Images',
    'video/': 'Videos',
    'audio/': 'Audio',
    'application/vnd.google-apps.folder': 'Folders',
    'application/zip': 'Archives',
    'text/': 'Documents'
}

class ProgressTracker:
    def __init__(self, task_id, total, action, meta=None):
        self.task_id = task_id
        self.total = total
        self.current = 0
        self.skipped = 0
        self.status = "Initializing..."
        self.action = action
        self.last_file = ""
        self.categories = {}
        self.meta = meta or {}
        self.start_time = time.time()
        self.is_complete = False
        self.save()

    def update_scan_status(self, count):
        """Updates status during pre-scan phase without incrementing progress."""
        self.status = f"Scanning Source... ({count} found)"
        self.save()

    def update(self, filename, mime=None, is_skipped=False):
        if is_skipped: self.skipped += 1
        else: self.current += 1
        self.status = "Processing..."
        self.last_file = filename
        if mime:
            cat = "Other"
            for m, label in MIME_MAP.items():
                if mime.startswith(m): cat = label; break
            self.categories[cat] = self.categories.get(cat, 0) + 1
        self.save()

    def complete(self, status="Completed"):
        self.is_complete = True
        self.status = status
        self.save()

    def save(self):
        TASKS[self.task_id] = {
            "id": self.task_id,
            "action": self.action,
            "total": self.total,
            "current": self.current,
            "skipped": self.skipped,
            "remaining": max(0, self.total - (self.current + self.skipped)),
            "percent": round(((self.current + self.skipped) / self.total * 100), 1) if self.total > 0 else 0,
            "status": self.status,
            "last_file": self.last_file[:40],
            "categories": self.categories,
            "meta": self.meta,
            "is_complete": self.is_complete,
            "elapsed": round(time.time() - self.start_time, 1)
        }

# --- HELPERS ---

def get_service(creds_json):
    creds = Credentials.from_authorized_user_info(json.loads(creds_json), SCOPES)
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    return build("drive", "v3", credentials=creds)

def extract_id(url):
    if not url: return None
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    if 'id=' in url: return url.split('id=')[1].split('&')[0]
    return url

def list_recursive(service, folder_id, tracker=None):
    """Recursively list files, updating tracker status if provided."""
    files = []
    page_token = None
    while True:
        try:
            q = f"'{folder_id}' in parents and trashed = false"
            res = service.files().list(q=q, fields="nextPageToken, files(id, name, mimeType, size, parents)", pageToken=page_token).execute()
            
            new_items = res.get('files', [])
            for f in new_items:
                if f['mimeType'] == 'application/vnd.google-apps.folder':
                    files.append(f)
                    files.extend(list_recursive(service, f['id'], tracker))
                else:
                    files.append(f)
            
            # UPDATE UI DURING SCAN
            if tracker and len(files) % 10 == 0:
                tracker.update_scan_status(len(files))

            page_token = res.get('nextPageToken')
            if not page_token: break
        except Exception: break
    return files

# --- API ---

@app.route('/api/run', methods=['POST'])
def handle_run():
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        try:
            service = get_service(data['creds'])
            
            # Action 1: Recursive Copy (Fixed)
            if action == "copy":
                sid, did = extract_id(data['src']), extract_id(data['dst'])
                # Initialize tracker immediately so UI shows up
                tr = ProgressTracker(task_id, 0, "Copying", {"src": sid[:8], "dst": did[:8]})
                
                # Pass tracker to scanner so it updates UI
                all_items = list_recursive(service, sid, tr)
                tr.total = len(all_items)
                tr.status = "Starting Copy..."
                tr.save()

                def clone(s_id, p_id):
                    m = service.files().get(fileId=s_id, fields="name").execute()
                    try:
                        nid = service.files().create(body={"name":m["name"], "mimeType":"application/vnd.google-apps.folder", "parents":[p_id] if p_id else []}, fields="id").execute()["id"]
                    except: nid = p_id # Fallback if root

                    tr.update(m['name'], 'application/vnd.google-apps.folder')
                    
                    # Fetch immediate children only for copying loop
                    level_items = service.files().list(q=f"'{s_id}' in parents and trashed=false").execute().get('files', [])
                    for it in level_items:
                        if it['mimeType'] == 'application/vnd.google-apps.folder': 
                            clone(it['id'], nid)
                        else:
                            service.files().copy(fileId=it['id'], body={"name":it['name'], "parents":[nid]}).execute()
                            tr.update(it['name'], it['mimeType'])
                
                clone(sid, did)
                tr.complete()

            # Action 2: Rename
            elif action == "rename":
                fid, s, r = extract_id(data['url']), data['search'], data['replace']
                tr = ProgressTracker(task_id, 0, "Renaming", {"find": s, "with": r})
                all_items = list_recursive(service, fid, tr)
                tr.total = len(all_items)
                tr.save()
                
                for it in all_items:
                    if s in it['name']:
                        nn = it['name'].replace(s, r)
                        service.files().update(fileId=it['id'], body={"name": nn}).execute()
                        tr.update(nn, it['mimeType'])
                    else: tr.update(it['name'], it['mimeType'], is_skipped=True)
                tr.complete()

            # Action 3: Count
            elif action == "count":
                fid = extract_id(data['url'])
                tr = ProgressTracker(task_id, 0, "Counting", {"target": fid[:8]})
                all_items = list_recursive(service, fid, tr)
                tr.total = len(all_items)
                for it in all_items: tr.update(it['name'], it['mimeType'])
                tr.complete()

            # Action 4: Automated Workflow
            elif action == "automated":
                src = extract_id(data['url'])
                tr = ProgressTracker(task_id, 100, "Automated Workflow")
                tr.update("Step 1: Cloning First Source")
                m = service.files().get(fileId=src, fields="name").execute()
                nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [UNPOSTED_FOLDER_ID]}, fields="id").execute()["id"]
                tr.update("Step 2: Merging Secondary Assets")
                for it in service.files().list(q=f"'{SECOND_SOURCE_FOLDER_ID}' in parents and trashed=false").execute().get('files', []):
                    service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                tr.update("Step 3: Branding .mp4 Files")
                for it in list_recursive(service, nid):
                    if it['name'].lower().endswith('.mp4'):
                        service.files().update(fileId=it['id'], body={"name": it['name'] + " Telegram@TechZoneX.mp4"}).execute()
                tr.complete()

            # Action 5: File Info
            elif action == "info":
                tr = ProgressTracker(task_id, 1, "Metadata Check")
                m = service.files().get(fileId=extract_id(data['url']), fields='name,size,mimeType').execute()
                tr.update(m['name'], m['mimeType'])
                tr.complete()

            # Action 6: Smart Replace
            elif action == "smart_replace":
                t, s, r = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                meta = service.files().get(fileId=s, fields='size,mimeType').execute()
                tr = ProgressTracker(task_id, 0, "Smart Replace", {"match": meta.get('size')})
                all_items = list_recursive(service, t, tr)
                
                matches = [f for f in all_items if f.get('size') == meta.get('size') and f.get('mimeType') == meta.get('mimeType')]
                tr.total = len(matches)
                tr.save()

                for it in matches:
                    p = it['parents'][0] if 'parents' in it else None
                    service.files().delete(fileId=it['id']).execute()
                    service.files().copy(fileId=r, body={"name": it['name'], "parents":[p] if p else []}).execute()
                    tr.update(it['name'], it['mimeType'])
                tr.complete()

            # Action 7: Distribution
            elif action == "distribute":
                t, s = extract_id(data['target']), extract_id(data['source'])
                meta = service.files().get(fileId=s, fields='name,size,mimeType').execute()
                
                tr = ProgressTracker(task_id, 0, "Distribution", {"file": meta['name']})
                all_items = list_recursive(service, t, tr)
                folders = [f for f in all_items if f['mimeType'] == 'application/vnd.google-apps.folder']
                folders.insert(0, {'id': t})
                
                tr.total = len(folders)
                tr.save()

                for fid in folders:
                    q = f"'{fid['id']}' in parents and size = '{meta['size']}'"
                    if not service.files().list(q=q).execute().get('files', []):
                        service.files().copy(fileId=s, body={"name": meta['name'], "parents": [fid['id']]}).execute()
                        tr.update(f"Folder-{fid['id'][:5]}", meta['mimeType'])
                    else: tr.update(f"Folder-{fid['id'][:5]}", meta['mimeType'], is_skipped=True)
                tr.complete()

        except Exception as e:
            TASKS[task_id] = {"status": "Failed", "error": str(e)}

    threading.Thread(target=worker).start()
    return jsonify({"task_id": task_id})

@app.route('/api/status/<tid>')
def get_status(tid): return jsonify(TASKS.get(tid, {"status": "Waiting"}))

@app.route('/auth/login')
def login():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES)
    f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    u, s = f.authorization_url(access_type='offline', prompt='consent')
    session['state'] = s
    return redirect(u)

@app.route('/callback')
def callback():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state'))
    f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    f.fetch_token(authorization_response=request.url)
    return redirect(f"{FRONTEND_URL}#auth_data={urllib.parse.quote(f.credentials.to_json())}")

@app.route('/')
def h(): return "OK", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get("PORT", 8000)))


