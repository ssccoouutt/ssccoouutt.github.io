# ==========================================
# KOYEB BACKEND (Python Server Only)
# ==========================================
FROM python:3.9-slim

# 1. Install System Tools (FFmpeg, Fonts, ImageMagick)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential libmagic1 file procps fonts-liberation && \
    # Fix ImageMagick security policy to allow text
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install Python Dependencies (FIXED VERSIONS)
# decorator<5.0 is REQUIRED for moviepy 1.0.3
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
    "Pillow==10.0.0" \
    "imageio-ffmpeg==0.4.9" \
    "decorator<5.0" \
    proglog \
    tqdm

# Create temp folders
RUN mkdir -p /tmp drive

# 3. Write the Backend Code (app.py)
RUN cat << 'EOF' > app.py
import os, json, uuid, time, io, sys, logging, traceback, threading
import numpy as np
from flask import Flask, request, jsonify, redirect, session, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
from moviepy.editor import VideoFileClip, ImageClip, CompositeVideoClip
from PIL import Image, ImageDraw, ImageFont

# --- LOGGING ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s', handlers=[logging.StreamHandler(sys.stdout)])
logger = logging.getLogger(__name__)

# --- CONFIG ---
# UPDATE THIS: The URL where your GitHub Pages is hosted
FRONTEND_URL = "https://techzone3201.github.io" 
# UPDATE THIS: Your Koyeb URL
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"

TEMP_DIR = "/tmp"
SYSTEM_FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"

RAW_CREDENTIALS = {
    "web": {
        "client_id": "704057951722-i19ln87gtlofufuet9okb9mvdj9t9hel.apps.googleusercontent.com",
        "project_id": "teledrive-pro",
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
        "client_secret": "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",
        "redirect_uris": [f"{SERVER_DOMAIN}/callback"],
        "javascript_origins": [SERVER_DOMAIN, FRONTEND_URL, "https://techzonex.store"]
    }
}

os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]

app = Flask(__name__)
app.secret_key = "production_watermark_key"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}

# --- HELPERS ---
def get_service(creds):
    c = Credentials.from_authorized_user_info(json.loads(creds), SCOPES)
    if c.expired and c.refresh_token: c.refresh(Request())
    return build("drive", "v3", credentials=c)

def download_file(service, fid, path):
    logger.info(f"Downloading {fid}...")
    req = service.files().get_media(fileId=fid)
    with io.FileIO(path, 'wb') as fh:
        d = MediaIoBaseDownload(fh, req)
        done = False
        while not done: _, done = d.next_chunk()

# --- WATERMARK PROCESSING ---
def process_video_logic(video_path, output_path, wtype, text, logo_path):
    logger.info(f"Processing Video: {wtype}")
    video = VideoFileClip(video_path)
    
    if wtype == "image":
        # Static Logo Logic
        if not os.path.exists(logo_path): raise Exception("Logo file missing")
        watermark_img = Image.open(logo_path)
        if watermark_img.mode != 'RGBA': watermark_img = watermark_img.convert('RGBA')
        watermark_np = np.array(watermark_img)
        
        if len(watermark_np.shape) == 2: watermark_np = np.stack([watermark_np]*3, axis=-1)
        elif watermark_np.shape[2] == 4: watermark_np = watermark_np[..., :3]

        watermark_height = int(video.h * 0.07)
        logo_clip = (ImageClip(watermark_np)
                     .set_duration(video.duration)
                     .resize(height=watermark_height)
                     .set_opacity(1.0)
                     .set_pos(('right', 'bottom')))
        final = CompositeVideoClip([video, logo_clip])
    
    else:
        # Scrolling Text Logic
        try: font = ImageFont.truetype(SYSTEM_FONT, 50)
        except: font = ImageFont.load_default()
        
        dummy = ImageDraw.Draw(Image.new('RGB', (1, 1)))
        bbox = dummy.textbbox((0, 0), text, font=font)
        text_width = bbox[2] - bbox[0]
        text_height = bbox[3] - bbox[1]
        
        # Adaptive Speed
        if video.duration <= 10: scroll_speed = 80; initial_delay = 0; cycle_gap = 2
        elif video.duration <= 30: scroll_speed = 60; initial_delay = 1; cycle_gap = 5
        else: scroll_speed = 40; initial_delay = 30; cycle_gap = 30
            
        text_padding = 15; bottom_margin = 50

        def scroll_filter(get_frame, t):
            frame = get_frame(t)
            if t < initial_delay: return frame
            pil_img = Image.fromarray(frame); draw = ImageDraw.Draw(pil_img, 'RGBA')
            time_since_start = max(0, t - initial_delay)
            
            if video.duration <= 10:
                loop_duration = (video.w + text_width) / scroll_speed
                progress = (time_since_start % loop_duration) / loop_duration
                x_pos = int(video.w - progress * (video.w + text_width))
            else:
                active_duration = (video.w + text_width) / scroll_speed
                total_cycle = active_duration + cycle_gap
                time_in_cycle = time_since_start % total_cycle
                if time_in_cycle <= active_duration:
                    progress = time_in_cycle / active_duration
                    x_pos = int(video.w - progress * (video.w + text_width))
                else: return frame 

            y_pos = video.h - bottom_margin - text_height
            draw.rectangle([(x_pos - text_padding, y_pos - text_padding),
                 (x_pos + text_width + text_padding, y_pos + text_height + text_padding)], fill=(0, 0, 0, 230))
            draw.text((x_pos, y_pos - bbox[1]), text, font=font, fill=(255, 255, 255, 255))
            return np.array(pil_img)

        final = video.fl(scroll_filter)

    # Render
    final.write_videofile(output_path, codec='libx264', audio_codec='aac', threads=4, preset='ultrafast', logger=None)
    video.close()
    if wtype == "image": final.close()

# --- API ENDPOINTS ---
@app.route('/api/run', methods=['POST'])
def run():
    d = request.json; tid = str(uuid.uuid4())[:8]
    def w():
        TASKS[tid] = {"status":"Starting", "pct":0, "done":False}
        try:
            s = get_service(d['creds']); fid = d['url'].split('file/d/')[1].split('/')[0]
            vin = f"{TEMP_DIR}/{tid}_i.mp4"; vout = f"{TEMP_DIR}/{tid}_o.mp4"; lin = f"{TEMP_DIR}/{tid}_l.png"
            
            TASKS[tid].update({"status":"Downloading Video", "pct":10}); download_file(s, fid, vin)
            if d['type'] == 'image':
                TASKS[tid].update({"status":"Downloading Logo", "pct":30}); download_file(s, d['logo_id'], lin)

            TASKS[tid].update({"status":"Processing", "pct":50}); process_video_logic(vin, vout, d['type'], d['text'], lin)

            TASKS[tid].update({"status":"Uploading", "pct":90})
            m = MediaFileUpload(vout, mimetype='video/mp4', resumable=True)
            s.files().create(body={'name': f"Watermarked_{tid}.mp4"}, media_body=m).execute()

            TASKS[tid].update({"status":"Done", "pct":100, "done":True, "url":f"{SERVER_DOMAIN}/api/dl/{tid}"})
        except Exception as e:
            logger.error(traceback.format_exc()); TASKS[tid].update({"status":f"Error: {str(e)}", "done":True})
    threading.Thread(target=w).start()
    return jsonify({"id": tid})

@app.route('/api/status/<tid>')
def status(tid): return jsonify(TASKS.get(tid, {"status":"Waiting"}))

@app.route('/api/dl/<tid>')
def dl(tid): return send_file(f"{TEMP_DIR}/{tid}_o.mp4", as_attachment=True, download_name="watermarked.mp4")

@app.route('/auth/login')
def login():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES); f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    u, s = f.authorization_url(access_type='offline', prompt='consent'); session['state'] = s; return redirect(u)

@app.route('/callback')
def callback():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state')); f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    f.fetch_token(authorization_response=request.url)
    # Redirect back to GitHub Pages with the token
    return redirect(f"{FRONTEND_URL}/#auth_data={json.dumps(f.credentials.to_json())}")

@app.route('/')
def index(): return "Koyeb Backend Active", 200

if __name__ == '__main__': app.run(host='0.0.0.0', port=8000)
EOF

# 4. Run Server
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "1", "--threads", "4"]
