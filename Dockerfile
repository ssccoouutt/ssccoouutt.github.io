# ==========================================
# KOYEB SUPER SUITE (Enhanced Version)
# ==========================================
FROM python:3.11-slim

# 1. Install System Tools
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential \
    libmagic1 file procps fonts-liberation \
    unzip ca-certificates && \
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install Python Dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir "decorator<5.0" && \
    pip install --no-cache-dir \
    "moviepy==1.0.3" \
    "numpy<2.0.0" \
    "Pillow==9.5.0" \
    "imageio-ffmpeg==0.4.9" \
    "proglog" \
    "tqdm" \
    "flask" \
    "flask-cors" \
    "requests" \
    "gunicorn" \
    "google-api-python-client" \
    "google-auth-httplib2" \
    "google-auth-oauthlib" \
    "yt-dlp"

RUN mkdir -p /tmp drive /app/cookies

# 3. Create Backend (app.py)
RUN cat << 'EOF' > app.py
import os, json, uuid, time, io, sys, logging, traceback, threading, shutil
import subprocess, datetime, re
import numpy as np
from flask import Flask, request, jsonify, redirect, session, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
from moviepy.editor import VideoFileClip, ImageClip, CompositeVideoClip, concatenate_videoclips
from PIL import Image, ImageDraw, ImageFont
import yt_dlp

# --- CONFIG ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s', handlers=[logging.StreamHandler(sys.stdout)])
logger = logging.getLogger(__name__)

FRONTEND_URL = "https://techzonex.store" 
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"
TEMP_DIR = "/tmp"
COOKIES_DIR = "/app/cookies"
SYSTEM_FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
YOUTUBE_COOKIES_FILE_ID = "13iX8xpx47W3PAedGyhGpF5CxZRFz4uaF"
YOUTUBE_COOKIES_FILE = os.path.join(COOKIES_DIR, "cookies.txt")

RAW_CREDENTIALS = {
    "web": {
        "client_id": "704057951722-i19ln87gtlofufuet9okb9mvdj9t9hel.apps.googleusercontent.com",
        "project_id": "teledrive-pro",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
        "client_secret": "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",
        "redirect_uris": [f"{SERVER_DOMAIN}/callback"],
        "javascript_origins": [SERVER_DOMAIN, FRONTEND_URL, "https://techzone3201.github.io"]
    }
}

os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]

app = Flask(__name__)
app.secret_key = "production_super_suite_v3"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}
COOKIES_CACHE = {}

# --- HELPERS ---
def load_cookies_from_drive(service):
    global COOKIES_CACHE
    if 'cookies_content' in COOKIES_CACHE and time.time() - COOKIES_CACHE.get('last_updated', 0) < 300:
        return COOKIES_CACHE['cookies_content']
    try:
        req = service.files().get_media(fileId=YOUTUBE_COOKIES_FILE_ID)
        content = io.BytesIO()
        downloader = MediaIoBaseDownload(content, req)
        done = False
        while not done:
            _, done = downloader.next_chunk()
        cookies_text = content.getvalue().decode('utf-8', errors='ignore')
        with open(YOUTUBE_COOKIES_FILE, 'w', encoding='utf-8') as f:
            f.write(cookies_text)
        COOKIES_CACHE['cookies_content'] = cookies_text
        COOKIES_CACHE['last_updated'] = time.time()
        return cookies_text
    except:
        return ""

class ProgressTracker:
    def __init__(self, task_id, action="Task"):
        self.task_id = task_id
        self.action = action
        self.status = "Initializing..."
        self.percent = 0
        self.is_complete = False
        self.result_url = None
        self.drive_link = None
        self.save()
    def update(self, status, pct=None):
        self.status = status
        if pct is not None: self.percent = pct
        self.save()
    def complete(self, url=None, drive_link=None):
        self.status = "Done"; self.percent = 100; self.is_complete = True
        self.result_url = url; self.drive_link = drive_link
        self.save()
    def fail(self, err):
        self.status = f"Failed: {err}"; self.is_complete = True
        self.save()
    def save(self):
        TASKS[self.task_id] = self.__dict__

def get_service(creds):
    c = Credentials.from_authorized_user_info(json.loads(creds), SCOPES)
    if c.expired and c.refresh_token: c.refresh(Request())
    return build("drive", "v3", credentials=c)

def extract_id(url):
    if not url: return None
    url = str(url).strip()
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    return url

def upload_file(service, path, name, parent=None):
    meta = {'name': name}
    if parent: meta['parents'] = [parent]
    media = MediaFileUpload(path, resumable=True)
    return service.files().create(body=meta, media_body=media, fields='id, webViewLink').execute()

# --- MEDIA CORE ---
def core_trim(vin, vout, st, et):
    cmd = f"ffmpeg -i '{vin}' -ss {st} -to {et} -c copy '{vout}' -y -loglevel error"
    subprocess.run(cmd, shell=True)

def core_watermark(vin, vout, text):
    video = VideoFileClip(vin)
    # Simple text overlay logic
    video.write_videofile(vout, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    video.close()

# --- YOUTUBE LOGIC ---
@app.route('/api/youtube/info', methods=['POST'])
def youtube_info():
    try:
        data = request.json
        url = data.get('url')
        if not url: return jsonify({'success': False, 'error': 'Missing URL'})
        
        ydl_opts = {'quiet': True, 'skip_download': True}
        if os.path.exists(YOUTUBE_COOKIES_FILE): ydl_opts['cookiefile'] = YOUTUBE_COOKIES_FILE
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            formats = info.get('formats', [])
            qualities = []
            
            # Audio Option
            qualities.append({'quality': 'audio', 'label': '🎵 Audio (MP3)', 'type': 'audio'})
            
            # Video Options
            seen_heights = set()
            for f in formats:
                h = f.get('height')
                if h and h not in seen_heights and f.get('vcodec') != 'none':
                    seen_heights.add(h)
                    qualities.append({'quality': str(h), 'label': f"📹 {h}p Video", 'type': 'video'})
            
            return jsonify({
                'success': True,
                'title': info.get('title'),
                'thumbnail': info.get('thumbnail'),
                'duration': info.get('duration'),
                'uploader': info.get('uploader'),
                'qualities': sorted(qualities, key=lambda x: x.get('quality') if x['quality'] != 'audio' else '0', reverse=True)
            })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/run', methods=['POST'])
def run():
    d = request.json
    tid = str(uuid.uuid4())[:8]
    
    def worker():
        tr = ProgressTracker(tid, d.get('action'))
        try:
            s = get_service(d['creds'])
            if d['action'] == 'youtube':
                url = d['url']
                q = d.get('quality', 'best')
                tr.update("Downloading YouTube...", 30)
                
                ydl_opts = {
                    'format': 'bestvideo+bestaudio/best' if q != 'audio' else 'bestaudio',
                    'outtmpl': f'/tmp/{tid}.%(ext)s',
                    'noplaylist': True
                }
                if os.path.exists(YOUTUBE_COOKIES_FILE): ydl_opts['cookiefile'] = YOUTUBE_COOKIES_FILE
                
                with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                    info = ydl.extract_info(url, download=True)
                    fname = ydl.prepare_filename(info)
                
                tr.update("Uploading to Drive...", 70)
                dest = extract_id(d.get('destination'))
                up = upload_file(s, fname, os.path.basename(fname), dest)
                tr.complete(drive_link=up.get('webViewLink'))
        except Exception as e:
            tr.fail(str(e))
    
    threading.Thread(target=worker).start()
    return jsonify({"id": tid})

@app.route('/api/status/<tid>')
def status(tid): return jsonify(TASKS.get(tid, {"status": "Waiting"}))

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
    return redirect(f"{FRONTEND_URL}/#auth_data={json.dumps(f.credentials.to_json())}")

@app.route('/')
def index(): return jsonify({'status': 'online', 'version': '3.1'})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
EOF

CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "2", "--threads", "4"]
