import os
import json
import logging
import threading
import urllib.parse
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

@app.route('/')
def health():
    return "TechZoneX Drive Engine Active", 200

@app.route('/drive')
@app.route('/drive/index.html')
def serve_drive():
    return send_from_directory('drive', 'index.html')

# --- AUTHENTICATION ---

@app.route('/auth/login')
def login():
    try:
        flow = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES)
        flow.redirect_uri = f"{SERVER_DOMAIN}/callback"
        authorization_url, state = flow.authorization_url(access_type='offline', include_granted_scopes='true', prompt='consent')
        session['state'] = state
        return redirect(authorization_url)
    except Exception as e:
        return f"Auth Error: {str(e)}", 500

@app.route('/callback')
def callback():
    try:
        state = session.get('state')
        flow = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=state)
        flow.redirect_uri = f"{SERVER_DOMAIN}/callback"
        flow.fetch_token(authorization_response=request.url)
        creds = flow.credentials
        
        # Pass the credentials back to the professional domain via URL Hash
        creds_data = urllib.parse.quote(creds.to_json())
        return redirect(f"{FRONTEND_URL}#auth_data={creds_data}")
    except Exception as e:
        return f"Callback Error: {str(e)}", 500

# --- DRIVE ENGINE ---

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

@app.route('/api/smart_replace', methods=['POST'])
def smart_replace():
    data = request.json
    def task():
        try:
            service = get_service(data['creds'])
            sample = service.files().get(fileId=extract_id(data['sample_url']), fields='size,mimeType').execute()
            s_size, s_mime, r_id = sample.get('size'), sample.get('mimeType'), extract_id(data['replace_url'])
            
            def recurse(fid):
                q = f"'{fid}' in parents and trashed = false"
                items = service.files().list(q=q, fields="files(id, name, size, mimeType, parents)").execute().get('files', [])
                for it in items:
                    if it['mimeType'] == 'application/vnd.google-apps.folder': recurse(it['id'])
                    elif it.get('size') == s_size and it.get('mimeType') == s_mime:
                        pid = it['parents'][0] if 'parents' in it else None
                        service.files().delete(fileId=it['id']).execute()
                        service.files().copy(fileId=r_id, body={"name": it['name'], "parents": [pid] if pid else []}).execute()
            recurse(extract_id(data['target_url']))
        except: pass
    threading.Thread(target=task).start()
    return jsonify({"status": "Smart Replacement Task Started"})

@app.route('/api/smart_distribute', methods=['POST'])
def smart_distribute():
    data = request.json
    def task():
        try:
            service = get_service(data['creds'])
            sid = extract_id(data['source_url'])
            smeta = service.files().get(fileId=sid, fields='name,size,mimeType').execute()
            
            def dist(fid):
                q = f"'{fid}' in parents and trashed = false and size = '{smeta['size']}'"
                if not service.files().list(q=q).execute().get('files', []):
                    service.files().copy(fileId=sid, body={"name": smeta['name'], "parents": [fid]}).execute()
                sq = f"'{fid}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
                for s in service.files().list(q=sq).execute().get('files', []): dist(s['id'])
            dist(extract_id(data['target_url']))
        except: pass
    threading.Thread(target=task).start()
    return jsonify({"status": "Smart Distribution Task Started"})

@app.route('/api/copy_folder', methods=['POST'])
def copy_folder():
    data = request.json
    def task():
        try:
            service = get_service(data['creds'])
            def clone(sid, pid):
                m = service.files().get(fileId=sid, fields="name").execute()
                nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [pid] if pid else []}, fields="id").execute()["id"]
                res = service.files().list(q=f"'{sid}' in parents and trashed = false", fields="files(id, name, mimeType)").execute()
                for it in res.get("files", []):
                    if it["mimeType"] == "application/vnd.google-apps.folder": clone(it["id"], nid)
                    else: service.files().copy(fileId=it["id"], body={"name": it["name"], "parents": [nid]}).execute()
            clone(extract_id(data['source_url']), extract_id(data['dest_url']))
        except: pass
    threading.Thread(target=task).start()
    return jsonify({"status": "Recursive Copy Task Started"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get("PORT", 8000)))


