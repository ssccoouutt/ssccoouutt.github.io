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
CRED_DOWNLOAD_URL = "https://drive.usercontent.google.com/download?id=1kePrDXIzaAxe_NQER1YEYvdEEmwbkFXR&export=download"
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

# Call download immediately
download_credentials()

# --- ROUTES FOR KOYEB & FRONTEND ---

@app.route('/')
def health_check():
    """Fixes the Koyeb Health Check 404 error"""
    return "Service is running", 200

@app.route('/drive')
@app.route('/drive/index.html')
def serve_drive():
    """Serves your HTML file directly from the drive folder"""
    return send_from_directory('drive', 'index.html')

# --- AUTH ROUTES ---

@app.route('/auth/login')
def login():
    flow = Flow.from_client_secrets_file(CLIENT_SECRET_FILE, scopes=SCOPES)
    flow.redirect_uri = f"{KOYEB_DOMAIN}/callback"
    authorization_url, state = flow.authorization_url(access_type='offline', include_granted_scopes='true', prompt='consent')
    session['state'] = state
    return redirect(authorization_url)

@app.route('/callback')
def callback():
    flow = Flow.from_client_secrets_file(CLIENT_SECRET_FILE, scopes=SCOPES, state=session['state'])
    flow.redirect_uri = f"{KOYEB_DOMAIN}/callback"
    flow.fetch_token(authorization_response=request.url)
    creds = flow.credentials
    return f"""
    <html><body><script>
        window.localStorage.setItem('drive_creds', '{creds.to_json()}');
        window.location.href = '/drive';
    </script></body></html>
    """

# --- DRIVE API ROUTES ---

def get_drive_service(creds_json):
    creds = Credentials.from_authorized_user_info(json.loads(creds_json), SCOPES)
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    return build("drive", "v3", credentials=creds)

def extract_id(url):
    if not url: return None
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    return url

@app.route('/api/list_info', methods=['POST'])
def get_info():
    try:
        data = request.json
        service = get_drive_service(data['creds'])
        file_id = extract_id(data['url'])
        meta = service.files().get(fileId=file_id, fields='name,size,mimeType').execute()
        return jsonify(meta)
    except Exception as e:
        return jsonify({"error": str(e)}), 400

@app.route('/api/smart_replace', methods=['POST'])
def smart_replace():
    data = request.json
    creds = data['creds']
    target_folder_id = extract_id(data['target_url'])
    sample_id = extract_id(data['sample_url'])
    replace_id = extract_id(data['replace_url'])

    def task():
        service = get_drive_service(creds)
        sample = service.files().get(fileId=sample_id, fields='size,mimeType').execute()
        s_size, s_mime = sample.get('size'), sample.get('mimeType')
        
        def scan_and_replace(folder_id):
            query = f"'{folder_id}' in parents and trashed = false"
            results = service.files().list(q=query, fields="files(id, name, size, mimeType, parents)").execute()
            for f in results.get('files', []):
                if f['mimeType'] == 'application/vnd.google-apps.folder':
                    scan_and_replace(f['id'])
                elif f.get('size') == s_size and f.get('mimeType') == s_mime:
                    parent_id = f['parents'][0] if 'parents' in f else None
                    try:
                        service.files().delete(fileId=f['id']).execute()
                        service.files().copy(fileId=replace_id, body={"name": f['name'], "parents": [parent_id] if parent_id else []}).execute()
                    except: pass

        scan_and_replace(target_folder_id)

    threading.Thread(target=task).start()
    return jsonify({"status": "Replacement started in background"})

@app.route('/api/smart_distribute', methods=['POST'])
def smart_distribute():
    data = request.json
    creds = data['creds']
    root_id = extract_id(data['target_url'])
    source_id = extract_id(data['source_url'])

    def task():
        service = get_drive_service(creds)
        src_meta = service.files().get(fileId=source_id, fields='name,size,mimeType').execute()
        
        def distribute(folder_id):
            query = f"'{folder_id}' in parents and trashed = false and size = '{src_meta['size']}'"
            exists = service.files().list(q=query).execute().get('files', [])
            if not exists:
                try:
                    service.files().copy(fileId=source_id, body={"name": src_meta['name'], "parents": [folder_id]}).execute()
                except: pass
            
            sub_query = f"'{folder_id}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
            subs = service.files().list(q=sub_query).execute().get('files', [])
            for s in subs: distribute(s['id'])

        distribute(root_id)

    threading.Thread(target=task).start()
    return jsonify({"status": "Distribution started in background"})

@app.route('/api/copy_recursive', methods=['POST'])
def copy_recursive():
    data = request.json
    creds = data['creds']
    src_id = extract_id(data['source_url'])
    dst_id = extract_id(data['dest_url'])

    def task():
        service = get_drive_service(creds)
        def recursive_copy(source_id, target_parent_id):
            meta = service.files().get(fileId=source_id, fields="name").execute()
            new_folder = service.files().create(body={
                "name": meta["name"], 
                "mimeType": "application/vnd.google-apps.folder", 
                "parents": [target_parent_id] if target_parent_id else []
            }, fields="id").execute()["id"]
            
            results = service.files().list(q=f"'{source_id}' in parents and trashed = false", fields="files(id, name, mimeType)").execute()
            for item in results.get("files", []):
                if item["mimeType"] == "application/vnd.google-apps.folder":
                    recursive_copy(item["id"], new_folder)
                else:
                    service.files().copy(fileId=item["id"], body={"name": item["name"], "parents": [new_folder]}).execute()
        
        recursive_copy(src_id, dst_id)

    threading.Thread(target=task).start()
    return jsonify({"status": "Recursive copy started"})

if __name__ == '__main__':
    port = int(os.environ.get("PORT", 8000))
    app.run(host='0.0.0.0', port=port)


