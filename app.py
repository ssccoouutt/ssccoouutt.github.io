import os
import json
import logging
import threading
import urllib.parse
import uuid
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

RAW_CREDENTIALS = {
    "web": {
        "client_id": "704057951722-i19ln87gtlofufuet9okb9mvdj9t9hel.apps.googleusercontent.com",
        "project_id": "teledrive-pro",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url": "https://www.googleapis.com/view/certs",
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

class ProgressTracker:
    def __init__(self, task_id, total):
        self.task_id = task_id
        self.total = total
        self.current = 0
        self.status = "Initializing..."
        self.last_file = ""
        self.data = {} # For returning info/count results
        TASKS[task_id] = self.to_dict()

    def update(self, filename, status="Processing"):
        self.current += 1
        self.status = status
        self.last_file = filename
        TASKS[self.task_id] = self.to_dict()

    def complete(self, final_status="Completed", data=None):
        self.status = final_status
        if data: self.data = data
        TASKS[self.task_id] = self.to_dict()

    def to_dict(self):
        return {
            "id": self.task_id,
            "total": self.total,
            "current": self.current,
            "percent": round((self.current / self.total * 100), 2) if self.total > 0 else 0,
            "status": self.status,
            "last_file": self.last_file[:30],
            "data": self.data
        }

# --- DRIVE ENGINE UTILS ---

def get_service(creds_json):
    creds = Credentials.from_authorized_user_info(json.loads(creds_json), SCOPES)
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    return build("drive", "v3", credentials=creds)

def extract_id(url):
    if not url: return None
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    return url

def list_all_files(service, folder_id):
    files = []
    page_token = None
    while True:
        q = f"'{folder_id}' in parents and trashed = false"
        res = service.files().list(q=q, fields="nextPageToken, files(id, name, mimeType, size, parents)", pageToken=page_token).execute()
        for f in res.get('files', []):
            if f['mimeType'] == 'application/vnd.google-apps.folder': files.extend(list_all_files(service, f['id']))
            else: files.append(f)
        page_token = res.get('nextPageToken')
        if not page_token: break
    return files

def list_all_folders(service, root_id):
    folders = [root_id]
    res = service.files().list(q=f"'{root_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false").execute()
    for f in res.get('files', []): folders.extend(list_all_folders(service, f['id']))
    return folders

# --- CORE LOGIC HANDLER ---

@app.route('/api/run', methods=['POST'])
def run_task():
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def background_task():
        try:
            service = get_service(data['creds'])
            
            # 1. Copy Folder (Recursive)
            if action == "copy":
                src, dst = extract_id(data['src']), extract_id(data['dst'])
                files = list_all_files(service, src)
                tracker = ProgressTracker(task_id, len(files))
                def clone(sid, pid):
                    m = service.files().get(fileId=sid, fields="name").execute()
                    nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [pid] if pid else []}, fields="id").execute()["id"]
                    for it in service.files().list(q=f"'{sid}' in parents and trashed=false").execute().get('files', []):
                        if it['mimeType'] == 'application/vnd.google-apps.folder': clone(it['id'], nid)
                        else:
                            service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                            tracker.update(it['name'])
                clone(src, dst)
                tracker.complete()

            # 2. Rename Files
            elif action == "rename":
                fid, s, r = extract_id(data['url']), data['search'], data['replace']
                files = list_all_files(service, fid)
                tracker = ProgressTracker(task_id, len(files))
                for f in files:
                    if s in f['name']:
                        nn = f['name'].replace(s, r)
                        service.files().update(fileId=f['id'], body={"name": nn}).execute()
                        tracker.update(nn, "Renamed")
                    else: tracker.update(f['name'], "Skipped")
                tracker.complete()

            # 3. Count Files
            elif action == "count":
                tracker = ProgressTracker(task_id, 1)
                files = list_all_files(service, extract_id(data['url']))
                tracker.complete("Done", {"count": len(files)})

            # 4. Automated Workflow
            elif action == "automated":
                # Hardcoded logic from your script
                UNPOSTED = "14tf687_8F4o2oYJTqyCZmvJjq45jRliy"
                SECOND_SRC = "12V7EnRIYcSgEtt0PR5fhV8cO22nzYuiv"
                first_src = extract_id(data['url'])
                
                tracker = ProgressTracker(task_id, 100) # Estimated
                tracker.update("Starting Copy 1")
                # Step A: Copy First Source to Unposted
                m = service.files().get(fileId=first_src, fields="name").execute()
                nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [UNPOSTED]}, fields="id").execute()["id"]
                
                # Step B: Copy contents of Second Source to that new folder
                tracker.update("Merging Second Source")
                for it in service.files().list(q=f"'{SECOND_SRC}' in parents and trashed=false").execute().get('files', []):
                    service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                
                # Step C: Rename .mp4
                tracker.update("Finalizing Names")
                for it in list_all_files(service, nid):
                    if it['name'].endswith('.mp4'):
                        service.files().update(fileId=it['id'], body={"name": it['name'] + " Telegram@TechZoneX.mp4"}).execute()
                tracker.complete()

            # 5. Check Info
            elif action == "info":
                tracker = ProgressTracker(task_id, 1)
                m = service.files().get(fileId=extract_id(data['url']), fields='size,name,mimeType').execute()
                tracker.complete("Done", m)

            # 6. Smart Replace
            elif action == "smart_replace":
                t_id, s_id, r_id = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                s_meta = service.files().get(fileId=s_id, fields='size,mimeType').execute()
                matches = [f for f in list_all_files(service, t_id) if f.get('size') == s_meta.get('size') and f.get('mimeType') == s_meta.get('mimeType')]
                tracker = ProgressTracker(task_id, len(matches))
                for f in matches:
                    p = f['parents'][0] if 'parents' in f else None
                    service.files().delete(fileId=f['id']).execute()
                    service.files().copy(fileId=r_id, body={"name": f['name'], "parents": [p] if p else []}).execute()
                    tracker.update(f['name'], "Replaced")
                tracker.complete()

            # 7. Smart Distribution
            elif action == "distribute":
                t_id, s_id = extract_id(data['target']), extract_id(data['source'])
                s_meta = service.files().get(fileId=s_id, fields='name,size,mimeType').execute()
                folders = list_all_folders(service, t_id)
                tracker = ProgressTracker(task_id, len(folders))
                for fid in folders:
                    q = f"'{fid}' in parents and size='{s_meta['size']}' and trashed=false"
                    if not service.files().list(q=q).execute().get('files', []):
                        service.files().copy(fileId=s_id, body={"name": s_meta['name'], "parents": [fid]}).execute()
                        tracker.update(f"Folder-{fid[:5]}", "Distributed")
                    else: tracker.update(f"Folder-{fid[:5]}", "Skipped")
                tracker.complete()

        except Exception as e:
            TASKS[task_id] = {"status": "Error", "error": str(e)}

    threading.Thread(target=background_task).start()
    return jsonify({"task_id": task_id})

@app.route('/api/status/<tid>')
def get_status(tid): return jsonify(TASKS.get(tid, {"status": "Unknown"}))

@app.route('/auth/login')
def login():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES)
    f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    url, state = f.authorization_url(access_type='offline', prompt='consent')
    session['state'] = state
    return redirect(url)

@app.route('/callback')
def callback():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state'))
    f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    f.fetch_token(authorization_response=request.url)
    return redirect(f"{FRONTEND_URL}#auth_data={urllib.parse.quote(f.credentials.to_json())}")

@app.route('/')
def h(): return "Healthy", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get("PORT", 8000)))

