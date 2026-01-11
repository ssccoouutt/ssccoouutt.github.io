# ==========================================
# KOYEB SUPER SUITE (Enhanced Version)
# ==========================================
FROM python:3.11-slim

# 1. Install System Tools + Node.js (JS Runtime for yt-dlp)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential \
    libmagic1 file procps fonts-liberation nodejs \
    unzip ca-certificates && \
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install Python Dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir "moviepy==1.0.3" "flask" "flask-cors" \
    "google-api-python-client" "google-auth-oauthlib" "yt-dlp" "gunicorn"

RUN mkdir -p /tmp /app/cookies

# 3. Create Backend (app.py)
RUN cat << 'EOF' > app.py
import os, json, uuid, time, io, logging, threading, subprocess
from flask import Flask, request, jsonify, redirect, session, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
import yt_dlp

# --- CONFIG ---
FRONTEND_URL = "https://techzonex.store" 
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"
COOKIES_FILE = "/app/cookies/cookies.txt"
YOUTUBE_COOKIES_FILE_ID = "13iX8xpx47W3PAedGyhGpF5CxZRFz4uaF"

RAW_CREDENTIALS = {
    "web": {
        "client_id": "704057951722-i19ln87gtlofufuet9okb9mvdj9t9hel.apps.googleusercontent.com",
        "project_id": "teledrive-pro",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "client_secret": "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",
        "redirect_uris": [f"{SERVER_DOMAIN}/callback"]
    }
}

app = Flask(__name__)
app.secret_key = "techzone_v4_secret"
CORS(app)
TASKS = {}

def load_cookies(service):
    try:
        req = service.files().get_media(fileId=YOUTUBE_COOKIES_FILE_ID)
        fh = io.BytesIO()
        downloader = MediaIoBaseDownload(fh, req)
        done = False
        while not done: _, done = downloader.next_chunk()
        with open(COOKIES_FILE, "wb") as f: f.write(fh.getvalue())
        return True
    except: return False

@app.route('/api/youtube/info', methods=['POST'])
def youtube_info():
    try:
        data = request.json
        url = data.get('url')
        service = build("drive", "v3", credentials=Credentials.from_authorized_user_info(json.loads(data['creds'])))
        load_cookies(service)
        
        ydl_opts = {'quiet': True, 'noplaylist': True}
        if os.path.exists(COOKIES_FILE): ydl_opts['cookiefile'] = COOKIES_FILE
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            qualities = []
            seen = set()
            for f in info.get('formats', []):
                h = f.get('height')
                if h and h not in seen and f.get('vcodec') != 'none':
                    seen.add(h)
                    qualities.append({'quality': str(h), 'label': f"📹 {h}p", 'type': 'video'})
            qualities.append({'quality': 'audio', 'label': '🎵 Audio (MP3)', 'type': 'audio'})
            return jsonify({'success': True, 'title': info['title'], 'thumbnail': info['thumbnail'], 'qualities': qualities})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/run', methods=['POST'])
def run():
    d = request.json
    tid = str(uuid.uuid4())[:8]
    def worker():
        TASKS[tid] = {'status': 'Starting...', 'percent': 10, 'is_complete': False}
        try:
            creds = Credentials.from_authorized_user_info(json.loads(d['creds']))
            service = build("drive", "v3", credentials=creds)
            load_cookies(service)
            
            ydl_opts = {
                'format': 'bestvideo+bestaudio/best' if d['quality'] != 'audio' else 'bestaudio',
                'outtmpl': f'/tmp/{tid}.%(ext)s',
                'cookiefile': COOKIES_FILE if os.path.exists(COOKIES_FILE) else None
            }
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                info = ydl.extract_info(d['url'], download=True)
                path = ydl.prepare_filename(info)
            
            media = MediaFileUpload(path, resumable=True)
            f = service.files().create(body={'name': os.path.basename(path), 'parents': [d.get('destination')] if d.get('destination') else []}, media_body=media).execute()
            TASKS[tid] = {'status': 'Done', 'percent': 100, 'is_complete': True, 'drive_link': f.get('webViewLink')}
        except Exception as e:
            TASKS[tid] = {'status': f'Error: {str(e)}', 'is_complete': True}
    threading.Thread(target=worker).start()
    return jsonify({'id': tid})

@app.route('/api/status/<tid>')
def status(tid): return jsonify(TASKS.get(tid, {'status': 'Unknown'}))

@app.route('/auth/login')
def login():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=["https://www.googleapis.com/auth/drive"])
    f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    u, _ = f.authorization_url(access_type='offline', prompt='consent')
    return redirect(u)

@app.route('/callback')
def callback():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=["https://www.googleapis.com/auth/drive"])
    f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    f.fetch_token(authorization_response=request.url)
    return redirect(f"{FRONTEND_URL}/#auth_data={json.dumps(f.credentials.to_json())}")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
EOF

CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200"]
