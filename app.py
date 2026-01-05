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

# Hardcoded IDs for Option 4 (Automated Workflow)
UNPOSTED_FOLDER_ID = "14tf687_8F4o2oYJTqyCZmvJjq45jRliy"
SECOND_SOURCE_FOLDER_ID = "12V7EnRIYcSgEtt0PR5fhV8cO22nzYuiv"

# Hardcoded Credentials (Stable & Fast)
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

# In-Memory Task Registry
TASKS = {}

# MIME Type Mapping for Reports
MIME_MAP = {
    'application/pdf': 'PDF Documents',
    'image/': 'Images',
    'video/': 'Videos',
    'audio/': 'Audio Files',
    'application/vnd.google-apps.folder': 'Folders',
    'application/zip': 'Archives',
    'text/': 'Text Docs'
}

class ProgressTracker:
    def __init__(self, task_id, total, action, meta=None):
        self.task_id = task_id
        self.total = total
        self.current = 0
        self.skipped = 0
        self.status = "Initializing"
        self.action = action
        self.last_file = "Scanning..."
        self.categories = {}
        self.meta = meta or {}
        self.start_time = time.time()
        self.is_complete = False
        self.save()

    def update(self, filename, mime=None, is_skipped=False):
        if is_skipped:
            self.skipped += 1
        else:
            self.current += 1
        
        self.last_file = filename
        if mime:
            cat = "Others"
            for m, label in MIME_MAP.items():
                if mime.startswith(m):
                    cat = label
                    break
            self.categories[cat] = self.categories.get(cat, 0) + 1
        self.save()

    def complete(self, status="Completed"):
        self.is_complete = True
        self.status = status
        self.save()

    def save(self):
        elapsed = time.time() - self.start_time
        processed = self.current + self.skipped
        percent = round((processed / self.total * 100), 1) if self.total > 0 else 0
        
        TASKS[self.task_id] = {
            "id": self.task_id,
            "action": self.action,
            "total": self.total,
            "current": self.current,
            "skipped": self.skipped,
            "remaining": max(0, self.total - processed),
            "percent": min(100, percent),
            "status": self.status,
            "last_file": self.last_file[:50], # Truncate long names
            "categories": self.categories,
            "meta": self.meta,
            "is_complete": self.is_complete,
            "elapsed": round(elapsed, 1)
        }

# --- GOOGLE DRIVE HELPERS ---

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

def list_recursive(service, folder_id):
    """Deep scan to get accurate total count before starting operations."""
    files = []
    page_token = None
    while True:
        try:
            q = f"'{folder_id}' in parents and trashed = false"
            res = service.files().list(q=q, fields="nextPageToken, files(id, name, mimeType, size, parents)", pageToken=page_token).execute()
            for f in res.get('files', []):
                if f['mimeType'] == 'application/vnd.google-apps.folder':
                    files.append(f)
                    files.extend(list_recursive(service, f['id']))
                else:
                    files.append(f)
            page_token = res.get('nextPageToken')
            if not page_token: break
        except: break
    return files

# --- API ENDPOINTS ---

@app.route('/api/run', methods=['POST'])
def run_task():
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        try:
            service = get_service(data['creds'])
            
            # --- 1. RECURSIVE COPY ---
            if action == "copy":
                src, dst = extract_id(data['src']), extract_id(data['dst'])
                all_files = list_recursive(service, src)
                tr = ProgressTracker(task_id, len(all_files), "Deep Copy", {"src": src[:10], "dst": dst[:10]})
                
                def clone(sid, pid):
                    meta = service.files().get(fileId=sid, fields="name").execute()
                    nid = service.files().create(body={"name": meta["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [pid] if pid else []}, fields="id").execute()["id"]
                    tr.update(meta['name'], 'application/vnd.google-apps.folder')
                    
                    # Shallow list for current level to process children
                    q = f"'{sid}' in parents and trashed=false"
                    level_items = service.files().list(q=q).execute().get('files', [])
                    for it in level_items:
                        if it['mimeType'] == 'application/vnd.google-apps.folder':
                            clone(it['id'], nid)
                        else:
                            service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                            tr.update(it['name'], it['mimeType'])
                
                clone(src, dst)
                tr.complete()

            # --- 2. RENAME FILES ---
            elif action == "rename":
                fid = extract_id(data['url'])
                search, replace = data['search'], data['replace']
                all_files = list_recursive(service, fid)
                tr = ProgressTracker(task_id, len(all_files), "Bulk Rename", {"query": search})
                
                for f in all_files:
                    if search in f['name']:
                        new_name = f['name'].replace(search, replace)
                        service.files().update(fileId=f['id'], body={"name": new_name}).execute()
                        tr.update(new_name, f['mimeType'])
                    else:
                        tr.update(f['name'], f['mimeType'], is_skipped=True)
                tr.complete()

            # --- 3. COUNT FILES ---
            elif action == "count":
                fid = extract_id(data['url'])
                tr = ProgressTracker(task_id, 1, "Quick Analysis")
                all_files = list_recursive(service, fid)
                tr.total = len(all_files)
                for f in all_files:
                    tr.update(f['name'], f['mimeType'])
                tr.complete()

            # --- 4. AUTOMATED WORKFLOW ---
            elif action == "automated":
                src = extract_id(data['url'])
                # Estimate 100 steps as we don't scan second source to save time
                tr = ProgressTracker(task_id, 100, "Auto-Workflow") 
                
                tr.update("Step 1: Cloning Primary Source")
                src_meta = service.files().get(fileId=src, fields="name").execute()
                nid = service.files().create(body={"name": src_meta["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [UNPOSTED_FOLDER_ID]}, fields="id").execute()["id"]
                
                tr.update("Step 2: Merging Secondary Source")
                second_items = service.files().list(q=f"'{SECOND_SOURCE_FOLDER_ID}' in parents and trashed=false").execute().get('files', [])
                for it in second_items:
                    service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                
                tr.update("Step 3: Branding .mp4 Files")
                final_files = list_recursive(service, nid)
                tr.total = len(final_files) + 10 # Adjust total
                tr.current = 10
                for f in final_files:
                    if f['name'].lower().endswith('.mp4'):
                        new_name = f['name'] + " Telegram@TechZoneX.mp4"
                        service.files().update(fileId=f['id'], body={"name": new_name}).execute()
                        tr.update(new_name, f['mimeType'])
                    else:
                        tr.update(f['name'], f['mimeType'], is_skipped=True)
                tr.complete()

            # --- 5. GET INFO ---
            elif action == "info":
                fid = extract_id(data['url'])
                tr = ProgressTracker(task_id, 1, "Metadata")
                meta = service.files().get(fileId=fid, fields="name,size,mimeType").execute()
                # Store full metadata in tracker for UI to show
                tr.meta = {"size": meta.get('size', 'N/A'), "type": meta['mimeType']}
                tr.update(meta['name'], meta['mimeType'])
                tr.complete()

            # --- 6. SMART REPLACE ---
            elif action == "smart_replace":
                target, sample, replace = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                s_meta = service.files().get(fileId=sample, fields="size,mimeType").execute()
                
                all_files = list_recursive(service, target)
                matches = [f for f in all_files if f.get('size') == s_meta.get('size') and f.get('mimeType') == s_meta.get('mimeType')]
                
                tr = ProgressTracker(task_id, len(matches), "Smart Replace", {"match_size": s_meta.get('size')})
                
                for f in matches:
                    parent = f['parents'][0] if 'parents' in f else None
                    service.files().delete(fileId=f['id']).execute()
                    service.files().copy(fileId=replace, body={"name": f['name'], "parents": [parent] if parent else []}).execute()
                    tr.update(f['name'], f['mimeType'])
                tr.complete()

            # --- 7. SMART DISTRIBUTION ---
            elif action == "distribute":
                target, source = extract_id(data['target']), extract_id(data['source'])
                s_meta = service.files().get(fileId=source, fields="name,size,mimeType").execute()
                
                all_items = list_recursive(service, target)
                folders = [f for f in all_items if f['mimeType'] == 'application/vnd.google-apps.folder']
                folders.insert(0, {'id': target}) # Add root
                
                tr = ProgressTracker(task_id, len(folders), "Distribution", {"file": s_meta['name']})
                
                for f in folders:
                    # Check if file exists in this folder with same size
                    q = f"'{f['id']}' in parents and size='{s_meta['size']}' and trashed=false"
                    exists = service.files().list(q=q).execute().get('files', [])
                    
                    if not exists:
                        service.files().copy(fileId=source, body={"name": s_meta['name'], "parents": [f['id']]}).execute()
                        tr.update(f"Folder-{f['id'][:5]}", "Folders")
                    else:
                        tr.update(f"Folder-{f['id'][:5]}", "Folders", is_skipped=True)
                tr.complete()

        except Exception as e:
            TASKS[task_id] = {"status": "Failed", "error": str(e)}

    threading.Thread(target=worker).start()
    return jsonify({"task_id": task_id})

@app.route('/api/status/<tid>')
def get_status(tid):
    return jsonify(TASKS.get(tid, {"status": "Waiting"}))

@app.route('/auth/login')
def login():
    flow = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES)
    flow.redirect_uri = f"{SERVER_DOMAIN}/callback"
    url, state = flow.authorization_url(access_type='offline', prompt='consent')
    session['state'] = state
    return redirect(url)

@app.route('/callback')
def callback():
    flow = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state'))
    flow.redirect_uri = f"{SERVER_DOMAIN}/callback"
    flow.fetch_token(authorization_response=request.url)
    creds_encoded = urllib.parse.quote(flow.credentials.to_json())
    # JUMP BACK TO FRONTEND WITH CREDENTIALS
    return redirect(f"{FRONTEND_URL}#auth_data={creds_encoded}")

@app.route('/')
def health(): return "Healthy", 200

@app.route('/drive')
@app.route('/drive/index.html')
def serve_frontend(): return send_from_directory('drive', 'index.html')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get("PORT", 8000)))


