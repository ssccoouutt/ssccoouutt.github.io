# ==========================================
# KOYEB BACKEND (Python Only)
# ==========================================
FROM python:3.9-slim

# 1. Install System Tools (FFmpeg, Fonts, etc.)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential libmagic1 file procps fonts-liberation && \
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install Python Deps
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    flask flask-cors requests google-api-python-client google-auth-httplib2 \
    google-auth-oauthlib gunicorn werkzeug "moviepy==1.0.3" "numpy<2.0.0" \
    Pillow imageio-ffmpeg "decorator>=4.0.2" proglog tqdm

# 3. Create Backend Script (app.py)
RUN cat << 'EOF' > app.py
import os, json, uuid, time, io, sys, logging, traceback, numpy as np, threading
from flask import Flask, request, jsonify, redirect, session, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
from moviepy.editor import VideoFileClip, ImageClip, CompositeVideoClip
from PIL import Image, ImageDraw, ImageFont

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s', handlers=[logging.StreamHandler(sys.stdout)])
logger = logging.getLogger(__name__)

# --- CONFIG ---
# YOUR FRONTEND URL (GitHub Pages / Custom Domain)
FRONTEND_URL = "https://techzonex.store"
# YOUR KOYEB URL (For callbacks)
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
        "javascript_origins": [FRONTEND_URL, "https://www.techzonex.store", SERVER_DOMAIN]
    }
}

os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]

app = Flask(__name__)
app.secret_key = "backend_only_secret"
# Allow CORS from your Domain
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}

def get_service(creds):
    c = Credentials.from_authorized_user_info(json.loads(creds), SCOPES)
    if c and c.expired and c.refresh_token: c.refresh(Request())
    return build("drive", "v3", credentials=c)

def download_file(service, fid, path):
    logger.info(f"DL {fid}...")
    req = service.files().get_media(fileId=fid)
    with io.FileIO(path, 'wb') as fh:
        d = MediaIoBaseDownload(fh, req)
        done = False
        while not done: _, done = d.next_chunk()

def process_watermark(vin, vout, type, text, logo_path):
    video = VideoFileClip(vin)
    if type == "text":
        font = ImageFont.truetype(SYSTEM_FONT, 40) if os.path.exists(SYSTEM_FONT) else ImageFont.load_default()
        texts = [t.strip() for t in text.split('|')] or ["@TechZoneX"]
        tm = []
        d = ImageDraw.Draw(Image.new('RGB',(1,1)))
        for t in texts:
            b = d.textbbox((0,0), t, font=font)
            tm.append({'w': b[2]-b[0], 'h': b[3]-b[1], 't': t, 'b': b})
        def fl(get_frame, t):
            if t < 5: return get_frame(t)
            img = Image.fromarray(get_frame(t)); d = ImageDraw.Draw(img, 'RGBA')
            ct = t - 5; tc = (video.w + max(m['w'] for m in tm))/40 + 30
            cm = tm[int(ct/tc)%len(tm)]; ad = (video.w + cm['w'])/40; ti = ct%tc
            if ti <= ad:
                p = ti/ad; x = int(video.w - p*(video.w+cm['w'])); y = video.h - 32 - cm['h']
                d.rectangle([(x,y), (x+cm['w']+20, y+cm['h']+20)], fill=(0,0,0,220))
                d.text((x+10, y+10-cm['b'][1]), cm['t'], font=font, fill=(255,255,255,255))
            return np.array(img)
        final = video.fl(fl)
    else:
        if not os.path.exists(logo_path): raise Exception("Logo file missing")
        logo = ImageClip(np.array(Image.open(logo_path).convert('RGBA'))).set_duration(video.duration).resize(height=int(video.h*0.07)).set_opacity(1.0).set_pos(('right','bottom'))
        final = CompositeVideoClip([video, logo])
    final.write_videofile(vout, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    video.close(); 
    if type == "image": final.close()

@app.route('/')
def health(): return "Backend Online", 200

@app.route('/api/run', methods=['POST'])
def run():
    d = request.json; tid = str(uuid.uuid4())[:8]
    def w():
        TASKS[tid] = {"status":"Starting", "pct":0, "done":False}
        try:
            s = get_service(d['creds']); fid = d['url'].split('file/d/')[1].split('/')[0]
            vin = f"{TEMP_DIR}/{tid}_i.mp4"; vout = f"{TEMP_DIR}/{tid}_o.mp4"; lin = f"{TEMP_DIR}/{tid}_l.png"
            TASKS[tid].update({"status":"Downloading", "pct":10}); download_file(s, fid, vin)
            if d['type'] == 'image': download_file(s, d['logo_id'], lin)
            TASKS[tid].update({"status":"Rendering", "pct":50}); process_watermark(vin, vout, d['type'], d['text'], lin)
            TASKS[tid].update({"status":"Uploading", "pct":90})
            m = MediaFileUpload(vout, mimetype='video/mp4', resumable=True)
            s.files().create(body={'name':'Watermarked.mp4'}, media_body=m).execute()
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
    # Redirect to GitHub Pages / Custom Domain
    return redirect(f"{FRONTEND_URL}/#auth_data={json.dumps(f.credentials.to_json())}")

if __name__ == '__main__': app.run(host='0.0.0.0', port=8000)
EOF

# 4. Run Gunicorn
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "1", "--threads", "4"]
