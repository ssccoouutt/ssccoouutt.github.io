import os
import json
import requests
import logging
import threading
from flask import Flask, request, jsonify, redirect, url_for, session, send_from_directory
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# Configuration
os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]
CLIENT_SECRET_FILE = 'credentials.json'
CRED_DOWNLOAD_URL = "https://drive.usercontent.google.com/download?id=1Bt2e9QpcA7u3ie9Ny81JS9ZsH1pPjwKa&export=download"
KOYEB_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"

app = Flask(__name__)
app.secret_key = os.urandom(24)
CORS(app)

# --- STARTUP: DOWNLOAD CREDENTIALS ---
def download_credentials():
    if not os.path.exists(CLIENT_SECRET_FILE):
        try:
            response = requests.get(CRED_DOWNLOAD_URL)
            with open(CLIENT_SECRET_FILE, 'wb') as f:
                f.write(response.content)
            print("Credentials downloaded successfully.")
        except Exception as e:
            print(f"Failed to download credentials: {e}")

download_credentials()

# --- HELPER UTILITIES ---

def get_drive_service(creds_json):
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

# --- WEB & AUTH ROUTES ---

@app.route('/')
def health():
    return "TechZoneX Drive Engine Active", 200

@app.route('/drive')
@app.route('/drive/index.html')
def serve_drive():
    return send_from_directory('drive', 'index.html')

@app.route('/auth/login')
def login():
    flow = Flow.from_client_secrets_file(CLIENT_SECRET_FILE, scopes=SCOPES)
    flow.redirect_uri = f"{KOYEB_DOMAIN}/callback"
    auth_url, state = flow.authorization_url(access_type='offline', include_granted_scopes='true', prompt='consent')
    session['state'] = state
    return redirect(auth_url)

@app.route('/callback')
def callback():
    flow = Flow.from_client_secrets_file(CLIENT_SECRET_FILE, scopes=SCOPES, state=session.get('state'))
    flow.redirect_uri = f"{KOYEB_DOMAIN}/callback"
    flow.fetch_token(authorization_response=request.url)
    creds = flow.credentials
    return f"<html><body><script>window.localStorage.setItem('drive_creds', '{creds.to_json()}'); window.location.href='/drive';</script></body></html>"

# --- CORE MANAGEMENT LOGIC (FROM YOUR SCRIPT) ---

@app.route('/api/smart_replace', methods=['POST'])
def smart_replace():
    data = request.json
    creds, target_url, sample_url, replace_url = data['creds'], data['target_url'], data['sample_url'], data['replace_url']
    
    def task():
        service = get_drive_service(creds)
        sample_meta = service.files().get(fileId=extract_id(sample_url), fields='size,mimeType').execute()
        s_size, s_mime = sample_meta.get('size'), sample_meta.get('mimeType')
        replace_id = extract_id(replace_url)

        def recurse(folder_id):
            query = f"'{folder_id}' in parents and trashed = false"
            items = service.files().list(q=query, fields="files(id, name, size, mimeType, parents)").execute().get('files', [])
            for item in items:
                if item['mimeType'] == 'application/vnd.google-apps.folder':
                    recurse(item['id'])
                elif item.get('size') == s_size and item.get('mimeType') == s_mime:
                    p_id = item['parents'][0] if 'parents' in item else None
                    service.files().delete(fileId=item['id']).execute()
                    service.files().copy(fileId=replace_id, body={"name": item['name'], "parents": [p_id] if p_id else []}).execute()
        
        recurse(extract_id(target_url))

    threading.Thread(target=task).start()
    return jsonify({"status": "Smart Replacement started"})

@app.route('/api/smart_distribute', methods=['POST'])
def smart_distribute():
    data = request.json
    creds, root_url, source_url = data['creds'], data['target_url'], data['source_url']

    def task():
        service = get_drive_service(creds)
        src_id = extract_id(source_url)
        src_meta = service.files().get(fileId=src_id, fields='name,size,mimeType').execute()
        
        def distribute(folder_id):
            # Check if exists
            q = f"'{folder_id}' in parents and trashed = false and size = '{src_meta['size']}' and mimeType = '{src_meta['mimeType']}'"
            if not service.files().list(q=q).execute().get('files', []):
                service.files().copy(fileId=src_id, body={"name": src_meta['name'], "parents": [folder_id]}).execute()
            
            # Recurse subfolders
            sq = f"'{folder_id}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
            subs = service.files().list(q=sq).execute().get('files', [])
            for s in subs: distribute(s['id'])
            
        distribute(extract_id(root_url))

    threading.Thread(target=task).start()
    return jsonify({"status": "Smart Distribution started"})

@app.route('/api/copy_folder', methods=['POST'])
def copy_folder():
    data = request.json
    creds, src_url, dst_url = data['creds'], data['source_url'], data['dest_url']

    def task():
        service = get_drive_service(creds)
        def deep_copy(source_id, target_parent_id):
            meta = service.files().get(fileId=source_id, fields="name").execute()
            new_id = service.files().create(body={"name": meta["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [target_parent_id] if target_parent_id else []}, fields="id").execute()["id"]
            res = service.files().list(q=f"'{source_id}' in parents and trashed = false", fields="files(id, name, mimeType)").execute()
            for item in res.get("files", []):
                if item["mimeType"] == "application/vnd.google-apps.folder":
                    deep_copy(item["id"], new_id)
                else:
                    service.files().copy(fileId=item["id"], body={"name": item["name"], "parents": [new_id]}).execute()
        
        deep_copy(extract_id(src_url), extract_id(dst_url))

    threading.Thread(target=task).start()
    return jsonify({"status": "Recursive Copy started"})

if __name__ == '__main__':
    port = int(os.environ.get("PORT", 8000))
    app.run(host='0.0.0.0', port=port)


