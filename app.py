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
    def __init__(self, task_id, total, action_name):
        self.task_id = task_id
        self.total = total
        self.current = 0
        self.status = "In Progress"
        self.action_name = action_name
        self.last_file = ""
        self.categories = {}
        self.start_time = time.time()
        self.is_complete = False
        self.save()

    def update(self, filename, mime=None):
        self.current += 1
        self.last_file = filename
        if mime:
            cat = "Other"
            for m, label in MIME_MAP.items():
                if mime.startswith(m):
                    cat = label
                    break
            self.categories[cat] = self.categories.get(cat, 0) + 1
        self.save()

    def complete(self):
        self.is_complete = True
        self.status = "Completed"
        self.save()

    def save(self):
        TASKS[self.task_id] = {
            "id": self.task_id,
            "action": self.action_name,
            "total": self.total,
            "current": self.current,
            "remaining": max(0, self.total - self.current),
            "percent": round((self.current / self.total * 100), 2) if self.total > 0 else 0,
            "status": self.status,
            "last_file": self.last_file[:40],
            "categories": self.categories,
            "is_complete": self.is_complete,
            "elapsed": round(time.time() - self.start_time, 1)
        }

# --- UTILS ---

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

def list_all(service, folder_id, folders_only=False):
    files = []
    page_token = None
    while True:
        q = f"'{folder_id}' in parents and trashed = false"
        if folders_only: q += " and mimeType = 'application/vnd.google-apps.folder'"
        res = service.files().list(q=q, fields="nextPageToken, files(id, name, mimeType, size)", pageToken=page_token).execute()
        for f in res.get('files', []):
            if f['mimeType'] == 'application/vnd.google-apps.folder':
                files.append(f)
                files.extend(list_all(service, f['id'], folders_only))
            else:
                if not folders_only: files.append(f)
        page_token = res.get('nextPageToken')
        if not page_token: break
    return files

# --- API ROUTES ---

@app.route('/api/run', methods=['POST'])
def run_task():
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def background_task():
        try:
            service = get_service(data['creds'])
            
            if action == "copy":
                src_id = extract_id(data['src'])
                dst_id = extract_id(data['dst'])
                # Pre-scan for total count
                all_items = list_all(service, src_id)
                tracker = ProgressTracker(task_id, len(all_items), "Recursive Copy")
                
                def clone(sid, pid):
                    m = service.files().get(fileId=sid, fields="name").execute()
                    nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [pid] if pid else []}, fields="id").execute()["id"]
                    tracker.update(m['name'], 'application/vnd.google-apps.folder')
                    items = service.files().list(q=f"'{sid}' in parents and trashed=false").execute().get('files', [])
                    for it in items:
                        if it['mimeType'] == 'application/vnd.google-apps.folder': clone(it['id'], nid)
                        else:
                            service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                            tracker.update(it['name'], it['mimeType'])
                clone(src_id, dst_id)
                tracker.complete()

            elif action == "smart_replace":
                t_id, s_id, r_id = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                sample = service.files().get(fileId=s_id, fields='size,mimeType').execute()
                all_files = list_all(service, t_id)
                matches = [f for f in all_files if f.get('size') == sample.get('size') and f.get('mimeType') == sample.get('mimeType')]
                tracker = ProgressTracker(task_id, len(matches), "Smart Replacement")
                for f in matches:
                    service.files().delete(fileId=f['id']).execute()
                    service.files().copy(fileId=r_id, body={"name": f['name']}).execute() # Simplified parents for speed
                    tracker.update(f['name'], f['mimeType'])
                tracker.complete()

            elif action == "count":
                all_items = list_all(service, extract_id(data['url']))
                tracker = ProgressTracker(task_id, len(all_items), "Quick Count")
                for f in all_items: tracker.update(f['name'], f['mimeType'])
                tracker.complete()

            elif action == "info":
                f_id = extract_id(data['url'])
                meta = service.files().get(fileId=f_id, fields='name,size,mimeType').execute()
                tracker = ProgressTracker(task_id, 1, "Metadata Check")
                tracker.update(meta['name'], meta['mimeType'])
                tracker.complete()

        except Exception as e:
            TASKS[task_id] = {"status": "Error", "error": str(e)}

    threading.Thread(target=background_task).start()
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
    creds_data = urllib.parse.quote(flow.credentials.to_json())
    return redirect(f"{FRONTEND_URL}#auth_data={creds_data}")

@app.route('/')
def health(): return "Ready", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get("PORT", 8000)))
