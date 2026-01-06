# ==========================================
# KOYEB BACKEND (All Features Restored)
# ==========================================
FROM python:3.9-slim

# 1. Install System Tools (FFmpeg, Fonts, ImageMagick)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential libmagic1 file procps fonts-liberation && \
    # Fix ImageMagick security policy to allow text rendering
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install Python Dependencies (CRITICAL FIXES APPLIED)
# - decorator<5.0: Required by MoviePy
# - Pillow==9.5.0: Required for ANTIALIAS support
# - numpy<2.0.0: Required for MoviePy compatibility
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
    "google-auth-oauthlib"

# Create storage folders
RUN mkdir -p /tmp drive

# 3. Write the "Big" Backend Code (app.py)
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
# UPDATE THESE IF NEEDED
FRONTEND_URL = "https://techzone3201.github.io" 
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"

TEMP_DIR = "/tmp"
SYSTEM_FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"

# Folder IDs for 'Auto' workflow
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
        "javascript_origins": [SERVER_DOMAIN, FRONTEND_URL, "https://techzonex.store"]
    }
}

os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]

app = Flask(__name__)
app.secret_key = "production_super_suite"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}
MIME_MAP = {'application/pdf':'PDF', 'image/':'Images', 'video/':'Videos', 'audio/':'Audio', 'application/vnd.google-apps.folder':'Folders', 'application/zip':'Archives', 'text/':'Documents'}

# --- HELPERS ---
class ProgressTracker:
    def __init__(self, task_id, action="Task"):
        self.task_id = task_id; self.action = action; self.status = "Initializing..."
        self.percent = 0; self.is_complete = False; self.result_url = None
        self.current = 0; self.total = 0; self.categories = {}
        self.save()
    def update(self, status, pct=None):
        if TASK_FLAGS.get(self.task_id): raise Exception("Cancelled")
        self.status = status; 
        if pct is not None: self.percent = pct
        self.save()
    def scan_update(self, count, cats=None):
        self.update(f"Scanning ({count})..."); self.categories = cats or self.categories; self.save()
    def complete(self, url=None):
        self.status = "Done"; self.percent = 100; self.is_complete = True; self.result_url = url; self.save()
    def fail(self, err):
        self.status = f"Failed: {err}"; self.is_complete = True; logger.error(err); self.save()
    def save(self):
        TASKS[self.task_id] = self.__dict__

def get_service(creds):
    c = Credentials.from_authorized_user_info(json.loads(creds), SCOPES)
    if c.expired and c.refresh_token: c.refresh(Request())
    return build("drive", "v3", credentials=c)

def extract_id(url):
    if not url: return None
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    if 'id=' in url: return url.split('id=')[1].split('&')[0]
    return url

def list_recursive(service, folder_id, tracker=None):
    files = []; counts = {v: 0 for v in MIME_MAP.values()}; counts['Other'] = 0; page = None
    while True:
        try:
            if tracker and TASK_FLAGS.get(tracker.task_id): raise Exception("Cancelled")
            res = service.files().list(q=f"'{folder_id}' in parents and trashed=false", fields="nextPageToken, files(id, name, mimeType, size, parents)", pageToken=page).execute()
            for f in res.get('files', []):
                cat = "Other"
                for m, label in MIME_MAP.items():
                    if f['mimeType'].startswith(m): cat = label; break
                counts[cat] += 1
                if f['mimeType'] == 'application/vnd.google-apps.folder':
                    files.append(f); sub_files, sub_counts = list_recursive(service, f['id'], tracker)
                    files.extend(sub_files); 
                    for k, v in sub_counts.items(): counts[k] += v
                else: files.append(f)
            if tracker and len(files) % 10 == 0: tracker.scan_update(len(files), counts)
            page = res.get('nextPageToken'); 
            if not page: break
        except: break
    return files, counts

def download_file(service, fid, path):
    logger.info(f"DL {fid}...")
    req = service.files().get_media(fileId=fid)
    with io.FileIO(path, 'wb') as fh:
        d = MediaIoBaseDownload(fh, req)
        done = False
        while not done: _, done = d.next_chunk()

def upload_file(service, path, name, parent=None):
    meta = {'name': name}; 
    if parent: meta['parents'] = [parent]
    media = MediaFileUpload(path, mimetype='video/mp4', resumable=True)
    return service.files().create(body=meta, media_body=media, fields='id').execute()

# --- VIDEO LOGIC (Watermark, Trim, Merge) ---
def process_watermark(vin, vout, wtype, text, logo_path):
    video = VideoFileClip(vin)
    if wtype == "image":
        if not os.path.exists(logo_path): raise Exception("Logo missing")
        img = Image.open(logo_path).convert('RGBA')
        img_np = np.array(img)
        # Fix shape
        if len(img_np.shape) == 2: img_np = np.stack([img_np]*3, axis=-1)
        elif img_np.shape[2] == 4: img_np = img_np[..., :3]
        
        logo = ImageClip(img_np).set_duration(video.duration).resize(height=int(video.h*0.07)).set_opacity(1.0).set_pos(('right','bottom'))
        final = CompositeVideoClip([video, logo])
    else:
        try: font = ImageFont.truetype(SYSTEM_FONT, 50)
        except: font = ImageFont.load_default()
        d = ImageDraw.Draw(Image.new('RGB',(1,1)))
        bbox = d.textbbox((0,0), text, font=font)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        
        # Adaptive speed
        spd = 80 if video.duration<=10 else (60 if video.duration<=30 else 40)
        delay = 0 if video.duration<=10 else (1 if video.duration<=30 else 30)
        gap = 2 if video.duration<=10 else (5 if video.duration<=30 else 30)

        def fl(get_frame, t):
            frame = get_frame(t)
            if t < delay: return frame
            img = Image.fromarray(frame); draw = ImageDraw.Draw(img, 'RGBA')
            ts = max(0, t - delay)
            
            if video.duration <= 10:
                ld = (video.w + tw) / spd; prog = (ts % ld) / ld
                x = int(video.w - prog * (video.w + tw))
            else:
                ad = (video.w + tw) / spd; tc = ad + gap; tic = ts % tc
                if tic <= ad: x = int(video.w - (tic/ad)*(video.w+tw))
                else: return frame
            
            y = video.h - 50 - th
            draw.rectangle([(x-15, y-15), (x+tw+15, y+th+15)], fill=(0,0,0,230))
            draw.text((x, y-bbox[1]), text, font=font, fill=(255,255,255,255))
            return np.array(img)
        final = video.fl(fl)
    
    final.write_videofile(vout, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    video.close(); 
    if wtype=="image": final.close()

# --- API ---
@app.route('/api/run', methods=['POST'])
def run():
    d = request.json; action = d.get('action'); tid = str(uuid.uuid4())[:8]
    def w():
        tr = ProgressTracker(tid, action)
        try:
            s = get_service(d['creds'])
            
            # 1. COPY
            if action == "copy":
                sid, did = extract_id(d['src']), extract_id(d['dst']) or 'root'
                files, stats = list_recursive(s, sid, tr); tr.total = len(files); tr.categories = stats; tr.save()
                def clone(s_id, p_id):
                    m = s.files().get(fileId=s_id, fields="name").execute()
                    nid = s.files().create(body={"name":m["name"], "mimeType":"application/vnd.google-apps.folder", "parents":[p_id] if p_id!='root' else []}, fields="id").execute()["id"]
                    tr.update(m['name'])
                    for it in s.files().list(q=f"'{s_id}' in parents and trashed=false").execute().get('files', []):
                        if it['mimeType'].endswith('folder'): clone(it['id'], nid)
                        else: s.files().copy(fileId=it['id'], body={"name":it['name'], "parents":[nid]}).execute(); tr.current+=1; tr.save()
                clone(sid, did); tr.complete()

            # 2. RENAME
            elif action == "rename":
                fid, f, r = extract_id(d['url']), d['search'], d['replace']
                files, stats = list_recursive(s, fid, tr); tr.total = len(files); tr.categories = stats; tr.save()
                for it in files:
                    if f in it['name']:
                        nn = it['name'].replace(f, r)
                        s.files().update(fileId=it['id'], body={"name": nn}).execute()
                        tr.update(nn); tr.current+=1
                    else: tr.current+=1
                    tr.save()
                tr.complete()

            # 3. COUNT/INFO
            elif action in ["count", "info"]:
                fid = extract_id(d['url']); files, stats = list_recursive(s, fid, tr)
                tr.total=len(files); tr.categories=stats; tr.complete()

            # 4. AUTO
            elif action == "automated":
                src = extract_id(d['url']); tr.update("Cloning...", 10)
                m = s.files().get(fileId=src, fields="name").execute()
                nid = s.files().create(body={"name":m["name"], "mimeType":"application/vnd.google-apps.folder", "parents":[UNPOSTED_FOLDER_ID]}, fields="id").execute()["id"]
                tr.update("Merging...", 40)
                for it in s.files().list(q=f"'{SECOND_SOURCE_FOLDER_ID}' in parents and trashed=false").execute().get('files', []):
                    s.files().copy(fileId=it['id'], body={"name":it['name'], "parents":[nid]}).execute()
                tr.update("Branding...", 70); files, _ = list_recursive(s, nid)
                for it in files:
                    if it['name'].endswith('.mp4'): s.files().update(fileId=it['id'], body={"name":it['name']+" Telegram@TechZoneX.mp4"}).execute()
                tr.complete()

            # 6. SMART REPLACE
            elif action == "smart_replace":
                t, smp, rep = extract_id(d['target']), extract_id(d['sample']), extract_id(d['replace'])
                meta = s.files().get(fileId=smp, fields='size').execute()
                files, _ = list_recursive(s, t, tr); matches = [f for f in files if f.get('size')==meta.get('size')]
                tr.total = len(matches); tr.save()
                for it in matches:
                    p = it['parents'][0] if 'parents' in it else None
                    s.files().delete(fileId=it['id']).execute()
                    s.files().copy(fileId=rep, body={"name":it['name'], "parents":[p] if p else []}).execute()
                    tr.current+=1; tr.save()
                tr.complete()

            # 7. DISTRIBUTE
            elif action == "distribute":
                t, src = extract_id(d['target']), extract_id(d['source'])
                meta = s.files().get(fileId=src, fields='name,size').execute()
                files, _ = list_recursive(s, t, tr); folders = [f for f in files if f['mimeType'].endswith('folder')]
                folders.insert(0, {'id':t}); tr.total = len(folders); tr.save()
                for fid in folders:
                    if not s.files().list(q=f"'{fid['id']}' in parents and size='{meta['size']}'").execute().get('files', []):
                        s.files().copy(fileId=src, body={"name":meta['name'], "parents":[fid['id']]}).execute()
                    tr.current+=1; tr.save()
                tr.complete()

            # 8. TRIM
            elif action == "trim":
                fid, st, et = extract_id(d['url']), d['start'], d['end']
                io_in, io_out = f"{TEMP_DIR}/{tid}_i.mp4", f"{TEMP_DIR}/{tid}_o.mp4"
                tr.update("Downloading", 20); download_file(s, fid, io_in)
                tr.update("Trimming", 50); subprocess.run(f"ffmpeg -i {io_in} -ss {st} -to {et} -c copy {io_out} -y", shell=True)
                tr.update("Uploading", 80); upload_file(s, io_out, "Trimmed.mp4")
                tr.complete(f"{SERVER_DOMAIN}/api/dl/{tid}")

            # 9. MERGE
            elif action == "merge":
                id1, id2 = extract_id(d['src1']), extract_id(d['src2'])
                f1, f2, fo, fl = f"{TEMP_DIR}/1_{tid}.mp4", f"{TEMP_DIR}/2_{tid}.mp4", f"{TEMP_DIR}/o_{tid}.mp4", f"{TEMP_DIR}/l_{tid}.txt"
                tr.update("DL Video 1", 10); download_file(s, id1, f1)
                tr.update("DL Video 2", 30); download_file(s, id2, f2)
                with open(fl,'w') as f: f.write(f"file '{f1}'\nfile '{f2}'")
                tr.update("Merging", 60); subprocess.run(f"ffmpeg -f concat -safe 0 -i {fl} -c copy {fo} -y", shell=True)
                tr.update("Uploading", 90); upload_file(s, fo, "Merged.mp4")
                tr.complete(f"{SERVER_DOMAIN}/api/dl/{tid}")

            # 10. WATERMARK
            elif action == "watermark":
                fid = extract_id(d['url'])
                vin, vout, lin = f"{TEMP_DIR}/{tid}_i.mp4", f"{TEMP_DIR}/{tid}_o.mp4", f"{TEMP_DIR}/{tid}_l.png"
                tr.update("DL Video", 10); download_file(s, fid, vin)
                if d['type'] == 'image':
                    lid = extract_id(d.get('logo_id')) # Extract ID from link
                    tr.update("DL Logo", 30); download_file(s, lid, lin)
                tr.update("Rendering", 50); process_watermark(vin, vout, d['type'], d['text'], lin)
                tr.update("Uploading", 90); upload_file(s, vout, f"Watermarked_{tid}.mp4")
                tr.complete(f"{SERVER_DOMAIN}/api/dl/{tid}")

        except Exception as e:
            tr.fail(str(e)); logger.error(traceback.format_exc())

    threading.Thread(target=w).start()
    return jsonify({"id": tid})

@app.route('/api/get_duration', methods=['POST'])
def get_duration():
    try:
        s = get_service(request.json['creds']); fid = extract_id(request.json['url'])
        meta = s.files().get(fileId=fid, fields='videoMediaMetadata').execute()
        sec = int(meta.get('videoMediaMetadata', {}).get('durationMillis', 0)) // 1000
        fmt = str(datetime.timedelta(seconds=sec))
        return jsonify({"duration": "0"+fmt if len(fmt)==7 else fmt})
    except: return jsonify({"error": "Failed"})

@app.route('/api/status/<tid>')
def status(tid): return jsonify(TASKS.get(tid, {"status":"Waiting"}))

@app.route('/api/dl/<tid>')
def dl(tid): return send_file(f"{TEMP_DIR}/o_{tid}.mp4", as_attachment=True, download_name="output.mp4")

@app.route('/auth/login')
def login():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES); f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    u, s = f.authorization_url(access_type='offline', prompt='consent'); session['state'] = s; return redirect(u)

@app.route('/callback')
def callback():
    f = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state')); f.redirect_uri = f"{SERVER_DOMAIN}/callback"
    f.fetch_token(authorization_response=request.url)
    return redirect(f"{FRONTEND_URL}/#auth_data={json.dumps(f.credentials.to_json())}")

@app.route('/')
def index(): return "Server Active", 200

if __name__ == '__main__': app.run(host='0.0.0.0', port=8000)
EOF

# 4. Run Server
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "1", "--threads", "4"]
