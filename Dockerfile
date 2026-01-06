# ==========================================
# 1. SETUP ENVIRONMENT
# ==========================================
FROM python:3.9-slim

# Install system dependencies (FFmpeg, ImageMagick, Fonts, Build Tools)
# We install 'procps' to help with debugging if needed
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential libmagic1 file procps && \
    # Fix ImageMagick policy for text rendering
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# ==========================================
# 2. INSTALL PYTHON DEPENDENCIES
# ==========================================
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    flask \
    flask-cors \
    requests \
    google-api-python-client \
    google-auth-httplib2 \
    google-auth-oauthlib \
    gunicorn \
    werkzeug \
    "moviepy==1.0.3" \
    "numpy<2.0.0" \
    Pillow \
    imageio-ffmpeg \
    "decorator>=4.0.2" \
    proglog \
    tqdm

# Create templates directory
RUN mkdir -p drive

# ==========================================
# 3. WRITE THE BACKEND (app.py)
# ==========================================
RUN cat << 'EOF' > app.py
import os
import json
import uuid
import time
import subprocess
import io
import datetime
import numpy as np
import threading
import requests
import logging
import traceback
import sys

from flask import Flask, request, jsonify, redirect, session, send_from_directory, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
from moviepy.editor import VideoFileClip, ImageClip, CompositeVideoClip
from PIL import Image, ImageDraw, ImageFont

# --- LOGGING SETUP ---
# This ensures logs appear in Koyeb's console
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

# --- CONFIGURATION ---
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"
FRONTEND_URL = "https://techzonex.store/drive"
TEMP_DIR = "/tmp"

# Hardcoded IDs
WATERMARK_LOGO_ID = "1tRu68CPASrZebcKAmAKpqfI6Hw_WHhiW"
FONT_URL = "https://github.com/liberationfonts/liberation-fonts/files/7261489/LiberationSans-Bold.ttf"

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
app.secret_key = "debug_watermark_mode"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}

# --- PROGRESS TRACKER ---
class ProgressTracker:
    def __init__(self, task_id):
        self.task_id = task_id
        self.status = "Initializing..."
        self.percent = 0
        self.is_complete = False
        self.cancelled = False
        self.result_url = None
        self.temp_files = []
        self.save()

    def update(self, status, percent):
        if TASK_FLAGS.get(self.task_id):
            raise Exception("Task Cancelled")
        self.status = status
        self.percent = percent
        logger.info(f"Task {self.task_id}: {status} ({percent}%)")
        self.save()

    def complete(self, result_url=None):
        self.status = "Done"
        self.percent = 100
        self.is_complete = True
        self.result_url = result_url
        self.save()

    def fail(self, error_msg):
        self.status = f"Failed: {error_msg}"
        self.is_complete = True
        logger.error(f"Task {self.task_id} Failed: {error_msg}")
        self.save()

    def save(self):
        TASKS[self.task_id] = {
            "id": self.task_id,
            "status": self.status,
            "percent": self.percent,
            "is_complete": self.is_complete,
            "result_url": self.result_url
        }

# --- GOOGLE HELPERS ---
def get_service(creds_json):
    creds = Credentials.from_authorized_user_info(json.loads(creds_json), SCOPES)
    if creds and creds.expired and creds.refresh_token: creds.refresh(Request())
    return build("drive", "v3", credentials=creds)

def extract_id(url):
    if not url: return None
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    if 'id=' in url: return url.split('id=')[1].split('&')[0]
    return url

def download_file(service, file_id, path):
    logger.info(f"Downloading file {file_id} to {path}")
    request = service.files().get_media(fileId=file_id)
    with io.FileIO(path, 'wb') as fh:
        downloader = MediaIoBaseDownload(fh, request)
        done = False
        while not done:
            status, done = downloader.next_chunk()
    logger.info("Download complete")

def upload_file(service, path, name):
    logger.info(f"Uploading {path} as {name}")
    file_metadata = {'name': name}
    media = MediaFileUpload(path, mimetype='video/mp4', resumable=True)
    f = service.files().create(body=file_metadata, media_body=media, fields='id').execute()
    logger.info(f"Upload complete. ID: {f.get('id')}")
    return f

# --- CORE WATERMARK LOGIC ---
def process_watermark(video_path, output_path, type, text=None, logo_path=None):
    logger.info(f"Starting MoviePy processing. Type: {type}")
    
    # 1. Load Video
    video = VideoFileClip(video_path)
    logger.info(f"Video loaded. Duration: {video.duration}, Size: {video.size}")

    if type == "text":
        # Download Font
        font_path = os.path.join(TEMP_DIR, "LiberationSans-Bold.ttf")
        if not os.path.exists(font_path):
            logger.info("Downloading font...")
            subprocess.run(["wget", "-O", font_path, FONT_URL], check=True)
        
        # Load Font
        try:
            font = ImageFont.truetype(font_path, 40)
        except Exception as e:
            logger.error(f"Font load failed: {e}. Using default.")
            font = ImageFont.load_default()

        # Parse Texts
        texts = [t.strip() for t in text.split('|')]
        if not texts or texts == [""]: texts = ["@TechZoneX"]

        # Pre-calc Metrics
        text_metrics = []
        temp_draw = ImageDraw.Draw(Image.new('RGB', (1, 1)))
        for txt in texts:
            bbox = temp_draw.textbbox((0, 0), txt, font=font)
            text_metrics.append({'width': bbox[2]-bbox[0], 'height': bbox[3]-bbox[1], 'text': txt, 'bbox': bbox})

        def frame_filter(get_frame, t):
            frame = get_frame(t)
            if t < 5: return frame # Delay
            
            # Convert frame to PIL
            pil_img = Image.fromarray(frame)
            draw = ImageDraw.Draw(pil_img, 'RGBA')
            
            cycle_time = t - 5
            total_cycle = (video.w + max(m['width'] for m in text_metrics)) / 40 + 30
            curr_metric = text_metrics[int(cycle_time/total_cycle) % len(text_metrics)]
            active_dur = (video.w + curr_metric['width']) / 40
            time_in = cycle_time % total_cycle
            
            if time_in <= active_dur:
                progress = time_in / active_dur
                x = int(video.w - progress * (video.w + curr_metric['width']))
                y = video.h - 32 - curr_metric['height']
                # Draw Background
                draw.rectangle([(x, y), (x+curr_metric['width']+20, y+curr_metric['height']+20)], fill=(0,0,0,220))
                # Draw Text
                draw.text((x+10, y+10-curr_metric['bbox'][1]), curr_metric['text'], font=font, fill=(255,255,255,255))
            
            return np.array(pil_img)

        final_clip = video.fl(frame_filter)

    else:
        # Logo Logic
        logger.info("Processing Logo Overlay...")
        logo_img = Image.open(logo_path).convert('RGBA')
        logo_np = np.array(logo_img)
        logo_h = int(video.h * 0.07)
        logo_clip = ImageClip(logo_np).set_duration(video.duration).resize(height=logo_h).set_opacity(1.0).set_pos(('right','bottom'))
        final_clip = CompositeVideoClip([video, logo_clip])

    # Write File
    logger.info("Writing video file (this takes time)...")
    # preset='ultrafast' is key for cloud environments to avoid timeouts
    final_clip.write_videofile(
        output_path, 
        codec='libx264', 
        audio_codec='aac', 
        preset='ultrafast', 
        threads=4, 
        logger=None # Disable MoviePy logger to prevent log spam, we rely on ours
    )
    video.close()
    if type == "image": final_clip.close()
    logger.info("Video processing finished.")

# --- API ---
@app.route('/api/run', methods=['POST'])
def handle_run():
    data = request.json
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        tr = ProgressTracker(task_id)
        try:
            logger.info(f"--- STARTING TASK {task_id} ---")
            service = get_service(data['creds'])
            
            file_id = extract_id(data['url'])
            if not file_id: raise Exception("Invalid Google Drive Link")

            wtype = data.get('type')
            wtext = data.get('text', "")

            # Paths
            vin = os.path.join(TEMP_DIR, f"in_{task_id}.mp4")
            vout = os.path.join(TEMP_DIR, f"wm_{task_id}.mp4")
            lin = os.path.join(TEMP_DIR, f"logo_{task_id}.png")
            tr.temp_files = [vin, vout, lin]

            # 1. Download
            tr.update("Downloading Video...", 10)
            download_file(service, file_id, vin)

            # 2. Prepare Logo if needed
            if wtype == "image":
                tr.update("Fetching Logo...", 30)
                download_file(service, WATERMARK_LOGO_ID, lin)

            # 3. Process
            tr.update("Rendering Watermark (Please Wait)...", 50)
            process_watermark(vin, vout, wtype, wtext, lin)

            # 4. Upload
            tr.update("Uploading Result...", 90)
            upload_file(service, vout, f"Watermarked_{task_id}.mp4")

            tr.complete(result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")
            logger.info(f"--- TASK {task_id} COMPLETED SUCCESSFULY ---")

        except Exception as e:
            # Capture full traceback for debugging
            err_msg = str(e)
            tb = traceback.format_exc()
            logger.error(f"TASK FAILED: {err_msg}\n{tb}")
            tr.fail(err_msg)

    threading.Thread(target=worker).start()
    return jsonify({"task_id": task_id})

# --- BASICS ---
@app.route('/')
def h(): return "OK", 200

@app.route('/api/status/<tid>')
def s(tid): return jsonify(TASKS.get(tid, {"status": "Waiting", "is_complete": False}))

@app.route('/api/dismiss/<tid>', methods=['POST'])
def d(tid):
    if tid in TASKS:
        for f in TASKS[tid].get('temp_files', []): 
            if os.path.exists(f): os.remove(f)
        del TASKS[tid]
    return jsonify({})

@app.route('/api/download/<tid>', methods=['GET'])
def dl(tid):
    if tid not in TASKS: return "404", 404
    for f in TASKS[tid].get('temp_files', []):
        if os.path.exists(f): return send_file(f, as_attachment=True, download_name="watermarked.mp4")
    return "404", 404

@app.route('/auth/login')
def l():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES); f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    u, s = f.authorization_url(access_type='offline', prompt='consent'); session['state'] = s; return redirect(u)

@app.route('/callback')
def cb():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state')); f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    f.fetch_token(authorization_response=request.url)
    return redirect(f"{FRONTEND_URL}#auth_data={json.dumps(f.credentials.to_json())}")

@app.route('/drive/index.html')
def i(): return send_from_directory('drive', 'index.html')

if __name__ == '__main__': app.run(host='0.0.0.0', port=8000)
EOF

# ==========================================
# 4. WRITE THE FRONTEND (index.html)
# ==========================================
RUN cat << 'EOF' > drive/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Watermark Tool</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
    <style>
        body { font-family: sans-serif; background: #030712; color: #e2e8f0; }
        .glass { background: #1e293b; border: 1px solid #334155; border-radius: 1rem; padding: 1.5rem; }
        input, select { background: #0f172a; border: 1px solid #334155; color: white; width: 100%; padding: 0.75rem; border-radius: 0.5rem; margin-bottom: 1rem; }
    </style>
</head>
<body class="p-6 max-w-lg mx-auto space-y-6">

    <div class="glass flex justify-between items-center">
        <h1 class="font-bold text-xl">Watermarker</h1>
        <div id="auth-btn"></div>
    </div>

    <div class="glass">
        <label class="text-xs text-gray-400">Video Link</label>
        <input type="text" id="url" placeholder="Google Drive Link">

        <label class="text-xs text-gray-400">Type</label>
        <select id="type">
            <option value="text">Scrolling Text</option>
            <option value="image">Logo Overlay</option>
        </select>

        <label class="text-xs text-gray-400">Text Content (if Type is Text)</label>
        <input type="text" id="text" placeholder="Enter text here">

        <button onclick="run()" class="w-full py-3 bg-blue-600 hover:bg-blue-700 rounded-lg font-bold">START PROCESS</button>
    </div>

    <div id="monitor" class="glass hidden">
        <div class="flex justify-between mb-2">
            <span id="status" class="font-bold text-yellow-500">Initializing...</span>
            <span id="pct">0%</span>
        </div>
        <div class="w-full bg-black h-2 rounded"><div id="bar" class="bg-blue-500 h-full transition-all" style="width:0%"></div></div>
        <div id="result-area" class="mt-4 hidden"></div>
    </div>

    <script>
        const API = "https://simple-liana-techzone3201-048a28fa.koyeb.app";
        let tid = null;

        function init() {
            const h = window.location.hash;
            if(h.includes('auth_data=')) {
                localStorage.setItem('creds', JSON.parse(decodeURIComponent(h.split('auth_data=')[1])));
                window.history.replaceState(null,null,' '); location.reload();
            }
            const c = localStorage.getItem('creds');
            document.getElementById('auth-btn').innerHTML = c ? 
                `<button onclick="localStorage.removeItem('creds');location.reload()" class="text-red-400 text-sm">Logout</button>` : 
                `<button onclick="location.href='${API}/auth/login'" class="bg-green-600 px-3 py-1 rounded text-sm">Login</button>`;
        }

        async function run() {
            if(!localStorage.getItem('creds')) return alert("Login First");
            
            document.getElementById('monitor').classList.remove('hidden');
            document.getElementById('result-area').innerHTML = "";
            document.getElementById('status').innerText = "Starting...";

            const body = {
                creds: localStorage.getItem('creds'),
                url: document.getElementById('url').value,
                type: document.getElementById('type').value,
                text: document.getElementById('text').value
            };

            try {
                const r = await fetch(API+'/api/run', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
                const d = await r.json();
                tid = d.task_id;
                poll();
            } catch(e) { alert("Error: " + e); }
        }

        function poll() {
            const intv = setInterval(async () => {
                const r = await fetch(API+'/api/status/'+tid);
                const s = await r.json();
                
                document.getElementById('status').innerText = s.status;
                document.getElementById('pct').innerText = s.percent + "%";
                document.getElementById('bar').style.width = s.percent + "%";

                if(s.is_complete) {
                    clearInterval(intv);
                    if(s.result_url) {
                        document.getElementById('status').className = "font-bold text-green-500";
                        document.getElementById('result-area').classList.remove('hidden');
                        document.getElementById('result-area').innerHTML = `<a href="${s.result_url}" class="block w-full text-center bg-green-600 py-2 rounded font-bold">DOWNLOAD VIDEO</a>`;
                    } else {
                        document.getElementById('status').className = "font-bold text-red-500";
                    }
                }
            }, 1000);
        }

        window.onload = init;
    </script>
</body>
</html>
EOF

# ==========================================
# 5. RUN THE SERVER
# ==========================================
# Restrict workers to 1 to prevent OOM
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "1", "--threads", "4"]
