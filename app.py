import os
import json
import logging
import threading
import urllib.parse
import uuid
import time
import subprocess
import io
import datetime
from flask import Flask, request, jsonify, redirect, session, send_from_directory, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
from googleapiclient.errors import HttpError

# --- CONFIGURATION ---
# UPDATE THESE TO MATCH YOUR ACTUAL URLS
FRONTEND_URL = "https://techzonex.store/drive"
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"
TEMP_DIR = "/tmp"

# Folder IDs
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
# Static key prevents session loss on server restart
app.secret_key = "my_static_secret_key_for_stability" 

# Enable CORS for all domains to prevent blocking
CORS(app, resources={r"/*": {"origins": "*"}})

# Global State
TASKS = {}
TASK_FLAGS = {}

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
        self.cancelled = False
        self.result_url = None
        self.temp_files = []
        self.save()

    def check_cancel(self):
        if TASK_FLAGS.get(self.task_id): 
            self.cancelled = True
            self.status = "Cancelled"
            self.is_complete = True
            self.save()
            raise Exception("Task Cancelled by User")

    def update_scan(self, count):
        self.check_cancel()
        self.status = f"Scanning Source ({count} found)..."
        self.save()

    def update(self, filename, mime=None, is_skipped=False):
        self.check_cancel()
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

    def complete(self, status="Completed", result_url=None):
        if not self.cancelled:
            self.is_complete = True
            self.status = status
            if result_url: self.result_url = result_url
            self.save()

    def save(self):
        pct = 0
        if self.is_complete: pct = 100
        elif self.total > 0:
            pct = round(((self.current + self.skipped) / self.total * 100), 1)
        
        TASKS[self.task_id] = {
            "id": self.task_id,
            "action": self.action,
            "total": self.total,
            "current": self.current,
            "skipped": self.skipped,
            "remaining": max(0, self.total - (self.current + self.skipped)),
            "percent": pct,
            "status": self.status,
            "last_file": self.last_file[:40],
            "categories": self.categories,
            "meta": self.meta,
            "is_complete": self.is_complete,
            "cancelled": self.cancelled,
            "result_url": self.result_url,
            "temp_files": self.temp_files,
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

def ms_to_timestamp(millis):
    """Converts milliseconds to HH:MM:SS format"""
    seconds = int(millis) // 1000
    return str(datetime.timedelta(seconds=seconds))

def list_recursive(service, folder_id, tracker=None):
    files = []
    page_token = None
    while True:
        try:
            if tracker: tracker.check_cancel()
            q = f"'{folder_id}' in parents and trashed = false"
            res = service.files().list(q=q, fields="nextPageToken, files(id, name, mimeType, size, parents)", pageToken=page_token).execute()
            for f in res.get('files', []):
                if f['mimeType'] == 'application/vnd.google-apps.folder':
                    files.append(f)
                    files.extend(list_recursive(service, f['id'], tracker))
                else: files.append(f)
            if tracker and len(files) % 20 == 0: tracker.update_scan(len(files))
            page_token = res.get('nextPageToken')
            if not page_token: break
        except Exception: break
    return files

def download_file(service, file_id, path, tracker=None):
    request = service.files().get_media(fileId=file_id)
    with io.FileIO(path, 'wb') as fh:
        downloader = MediaIoBaseDownload(fh, request)
        done = False
        while not done:
            if tracker: tracker.check_cancel()
            status, done = downloader.next_chunk()

def upload_file(service, path, name, parent_id=None):
    file_metadata = {'name': name}
    if parent_id: file_metadata['parents'] = [parent_id]
    media = MediaFileUpload(path, mimetype='video/mp4', resumable=True)
    return service.files().create(body=file_metadata, media_body=media, fields='id').execute()

# --- API ---

@app.route('/')
def health_check():
    return "OK", 200

@app.route('/api/get_duration', methods=['POST'])
def get_video_duration():
    try:
        data = request.json
        service = get_service(data['creds'])
        fid = extract_id(data['url'])
        meta = service.files().get(fileId=fid, fields='videoMediaMetadata').execute()
        duration_ms = meta.get('videoMediaMetadata', {}).get('durationMillis')
        if not duration_ms: return jsonify({"error": "Not a video or no duration data"}), 400
        
        fmt_duration = ms_to_timestamp(duration_ms)
        # Pad with leading zero if needed (e.g., 5:00 -> 05:00)
        if len(fmt_duration.split(":")) == 2: fmt_duration = "00:" + fmt_duration
        if len(fmt_duration) == 7: fmt_duration = "0" + fmt_duration
            
        return jsonify({"duration": fmt_duration})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/api/run', methods=['POST'])
def handle_run():
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        try:
            service = get_service(data['creds'])
            
            # Action 1: Recursive Copy
            if action == "copy":
                sid = extract_id(data['src'])
                did = extract_id(data['dst']) or 'root'
                tr = ProgressTracker(task_id, 0, "Copying", {"src": sid[:8], "dst": did[:8]})
                all_items = list_recursive(service, sid, tr)
                tr.total = len(all_items)
                tr.save()
                
                def clone(s_id, p_id):
                    tr.check_cancel()
                    m = service.files().get(fileId=s_id, fields="name").execute()
                    p_list = [p_id] if p_id and p_id != 'root' else []
                    nid = service.files().create(body={"name":m["name"], "mimeType":"application/vnd.google-apps.folder", "parents":p_list}, fields="id").execute()["id"]
                    tr.update(m['name'], 'application/vnd.google-apps.folder')
                    items = service.files().list(q=f"'{s_id}' in parents and trashed=false").execute().get('files', [])
                    for it in items:
                        if it['mimeType'] == 'application/vnd.google-apps.folder': clone(it['id'], nid)
                        else:
                            service.files().copy(fileId=it['id'], body={"name":it['name'], "parents":[nid]}).execute()
                            tr.update(it['name'], it['mimeType'])
                clone(sid, did)
                tr.complete()

            elif action == "rename":
                fid, s, r = extract_id(data['url']), data['search'], data['replace']
                tr = ProgressTracker(task_id, 0, "Renaming", {"find": s, "with": r})
                all_items = list_recursive(service, fid, tr)
                tr.total = len(all_items)
                tr.save()
                for it in all_items:
                    tr.check_cancel()
                    if s in it['name']:
                        nn = it['name'].replace(s, r)
                        service.files().update(fileId=it['id'], body={"name": nn}).execute()
                        tr.update(nn, it['mimeType'])
                    else: tr.update(it['name'], it['mimeType'], is_skipped=True)
                tr.complete()

            elif action == "count":
                fid = extract_id(data['url'])
                tr = ProgressTracker(task_id, 0, "Counting", {"target": fid[:8]})
                all_items = list_recursive(service, fid, tr)
                tr.total = len(all_items)
                for it in all_items: tr.update(it['name'], it['mimeType'])
                tr.complete()

            elif action == "automated":
                src = extract_id(data['url'])
                tr = ProgressTracker(task_id, 100, "Automated Workflow")
                tr.update("Cloning First Source")
                m = service.files().get(fileId=src, fields="name").execute()
                nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [UNPOSTED_FOLDER_ID]}, fields="id").execute()["id"]
                tr.update("Merging Second Source")
                for it in service.files().list(q=f"'{SECOND_SOURCE_FOLDER_ID}' in parents and trashed=false").execute().get('files', []):
                    service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                tr.update("Branding .mp4")
                for it in list_recursive(service, nid):
                    tr.check_cancel()
                    if it['name'].lower().endswith('.mp4'):
                        service.files().update(fileId=it['id'], body={"name": it['name'] + " Telegram@TechZoneX.mp4"}).execute()
                        tr.update(it['name'] + " Telegram@TechZoneX.mp4", 'video/mp4')
                tr.complete()

            elif action == "info":
                tr = ProgressTracker(task_id, 1, "Metadata")
                m = service.files().get(fileId=extract_id(data['url']), fields='name,size,mimeType').execute()
                tr.meta = {"size": m.get('size', 'N/A'), "type": m['mimeType']}
                tr.update(m['name'], m['mimeType'])
                tr.complete()

            elif action == "smart_replace":
                t, s, r = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                meta = service.files().get(fileId=s, fields='size,mimeType').execute()
                tr = ProgressTracker(task_id, 0, "Smart Replace", {"match": meta.get('size')})
                all_items = list_recursive(service, t, tr)
                matches = [f for f in all_items if f.get('size') == meta.get('size') and f.get('mimeType') == meta.get('mimeType')]
                tr.total = len(matches)
                tr.save()
                for it in matches:
                    tr.check_cancel()
                    p = it['parents'][0] if 'parents' in it else None
                    service.files().delete(fileId=it['id']).execute()
                    service.files().copy(fileId=r, body={"name": it['name'], "parents":[p] if p else []}).execute()
                    tr.update(it['name'], it['mimeType'])
                tr.complete()

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
                    tr.check_cancel()
                    q = f"'{fid['id']}' in parents and size = '{meta['size']}'"
                    if not service.files().list(q=q).execute().get('files', []):
                        service.files().copy(fileId=s, body={"name": meta['name'], "parents": [fid['id']]}).execute()
                        tr.update(f"Folder-{fid['id'][:5]}", "Folders")
                    else: tr.update(f"Folder-{fid['id'][:5]}", "Folders", is_skipped=True)
                tr.complete()

            # --- VIDEO TRIMMER ---
            elif action == "trim":
                file_id = extract_id(data['url'])
                start_time = data.get('start', '00:00:00')
                end_time = data.get('end', '00:00:10')
                
                tr = ProgressTracker(task_id, 4, "Trim Video", {"id": file_id[:8]})
                temp_in = os.path.join(TEMP_DIR, f"in_{task_id}.mp4")
                temp_out = os.path.join(TEMP_DIR, f"trim_{task_id}.mp4")
                tr.temp_files = [temp_in, temp_out]

                tr.status = "Downloading..."
                tr.save()
                download_file(service, file_id, temp_in, tr)
                tr.current = 1
                tr.save()

                tr.status = "Trimming (FFmpeg)..."
                tr.save()
                cmd = f"ffmpeg -i {temp_in} -ss {start_time} -to {end_time} -c copy {temp_out} -y"
                process = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if process.returncode != 0: raise Exception("FFmpeg failed")
                tr.current = 2
                tr.save()

                tr.status = "Uploading to Drive..."
                tr.save()
                file_name = f"Trimmed_{start_time.replace(':','')}-{end_time.replace(':','')}.mp4"
                up_file = upload_file(service, temp_out, file_name)
                tr.current = 3
                tr.save()

                # Clean input, keep output for download
                if os.path.exists(temp_in): os.remove(temp_in)
                
                tr.current = 4
                tr.complete(status="Uploaded & Ready", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")

            # --- VIDEO MERGER ---
            elif action == "merge":
                id1 = extract_id(data['src1'])
                id2 = extract_id(data['src2'])
                
                tr = ProgressTracker(task_id, 5, "Merge Videos")
                f1 = os.path.join(TEMP_DIR, f"m1_{task_id}.mp4")
                f2 = os.path.join(TEMP_DIR, f"m2_{task_id}.mp4")
                f_out = os.path.join(TEMP_DIR, f"merged_{task_id}.mp4")
                list_file = os.path.join(TEMP_DIR, f"list_{task_id}.txt")
                tr.temp_files = [f1, f2, f_out, list_file]

                tr.status = "Downloading Video 1..."
                tr.save()
                download_file(service, id1, f1, tr)
                tr.current = 1
                
                tr.status = "Downloading Video 2..."
                tr.save()
                download_file(service, id2, f2, tr)
                tr.current = 2
                tr.save()

                tr.status = "Merging..."
                tr.save()
                with open(list_file, 'w') as f:
                    f.write(f"file '{f1}'\nfile '{f2}'")
                
                cmd = f"ffmpeg -f concat -safe 0 -i {list_file} -c copy {f_out} -y"
                process = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if process.returncode != 0: raise Exception("Merge failed (codec mismatch?)")
                tr.current = 3

                tr.status = "Uploading to Drive..."
                tr.save()
                upload_file(service, f_out, "Merged_Video.mp4")
                tr.current = 4
                
                if os.path.exists(f1): os.remove(f1)
                if os.path.exists(f2): os.remove(f2)
                
                tr.current = 5
                tr.complete(status="Uploaded", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")

        except Exception as e:
            msg = str(e)
            if "Cancelled" in msg or TASK_FLAGS.get(task_id):
                TASKS[task_id]['status'] = "Cancelled"
                TASKS[task_id]['cancelled'] = True
            else:
                TASKS[task_id]['status'] = f"Failed: {msg}"
            TASKS[task_id]['is_complete'] = True

    threading.Thread(target=worker).start()
    return jsonify({"task_id": task_id})

@app.route('/api/cancel/<tid>', methods=['POST'])
def cancel_task(tid):
    if tid in TASKS:
        TASK_FLAGS[tid] = True
        TASKS[tid]['status'] = "Cancelling..."
    return jsonify({"status": "Signal Sent"})

@app.route('/api/dismiss/<tid>', methods=['POST'])
def dismiss_task(tid):
    if tid in TASKS:
        for f in TASKS[tid].get('temp_files', []):
            try:
                if os.path.exists(f): os.remove(f)
            except: pass
        del TASKS[tid]
    if tid in TASK_FLAGS: del TASK_FLAGS[tid]
    return jsonify({"status": "Dismissed"})

@app.route('/api/download/<tid>', methods=['GET'])
def download_result(tid):
    if tid not in TASKS: return "Task not found", 404
    for f in TASKS[tid].get('temp_files', []):
        if os.path.exists(f) and ("trim" in f or "merged" in f):
            return send_file(f, as_attachment=True, download_name="video_output.mp4")
    return "File cleaned up or missing", 404

@app.route('/api/status/<tid>')
def get_status(tid): return jsonify(TASKS.get(tid, {"status": "Waiting", "is_complete": False}))

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

@app.route('/drive')
@app.route('/drive/index.html')
def s(): return send_from_directory('drive', 'index.html')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get("PORT", 8000)))
