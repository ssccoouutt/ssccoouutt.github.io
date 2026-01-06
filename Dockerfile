# ==========================================
# 1. SETUP ENVIRONMENT
# ==========================================
FROM python:3.9-slim

# Install system dependencies (FFmpeg, ImageMagick, Fonts, Build Tools)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget git build-essential libmagic1 file && \
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
# We install directly here (no requirements.txt needed)
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
# We use a 'heredoc' to write the Python code into app.py right now
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

from flask import Flask, request, jsonify, redirect, session, send_from_directory, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
from moviepy.editor import VideoFileClip, ImageClip, CompositeVideoClip
from PIL import Image, ImageDraw, ImageFont

# CONFIGURATION
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"
FRONTEND_URL = "https://techzonex.store/drive"
TEMP_DIR = "/tmp"

UNPOSTED_FOLDER_ID = "14tf687_8F4o2oYJTqyCZmvJjq45jRliy"
SECOND_SOURCE_FOLDER_ID = "12V7EnRIYcSgEtt0PR5fhV8cO22nzYuiv"
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
app.secret_key = "static_key_for_persistence_fix"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}
MIME_MAP = {'application/pdf':'PDF', 'image/':'Images', 'video/':'Videos', 'audio/':'Audio', 'application/vnd.google-apps.folder':'Folders', 'application/zip':'Archives', 'text/':'Documents'}

class ProgressTracker:
    def __init__(self, task_id, total, action, meta=None):
        self.task_id = task_id; self.total = total; self.current = 0; self.skipped = 0
        self.status = "Initializing..."; self.action = action; self.last_file = ""; self.categories = {} 
        self.meta = meta or {}; self.start_time = time.time(); self.is_complete = False
        self.cancelled = False; self.result_url = None; self.temp_files = []
        self.save()
    def check_cancel(self):
        if TASK_FLAGS.get(self.task_id): 
            self.cancelled = True; self.status = "Cancelled"; self.is_complete = True; self.save(); raise Exception("Task Cancelled")
    def update_scan(self, count, categories=None):
        self.check_cancel(); self.status = "Scanning..."; 
        if categories: self.categories = categories
        self.save()
    def update(self, filename, mime=None, is_skipped=False):
        self.check_cancel()
        if is_skipped: self.skipped += 1
        else: self.current += 1
        self.status = "Processing..."; self.last_file = filename; self.save()
    def complete(self, status="Completed", result_url=None):
        if not self.cancelled: self.is_complete = True; self.status = status; self.result_url = result_url; self.save()
    def save(self):
        pct = 0
        if self.is_complete: pct = 100
        elif self.total > 0: pct = round(((self.current + self.skipped) / self.total * 100), 1)
        TASKS[self.task_id] = {
            "id": self.task_id, "action": self.action, "total": self.total, "current": self.current, "skipped": self.skipped, 
            "remaining": max(0, self.total - (self.current + self.skipped)), "percent": pct, "status": self.status, 
            "last_file": self.last_file[:40], "categories": self.categories, "meta": self.meta, "is_complete": self.is_complete,
            "cancelled": self.cancelled, "result_url": self.result_url
        }

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

def list_recursive(service, folder_id, tracker=None):
    files = []; counts = {v: 0 for v in MIME_MAP.values()}; counts['Other'] = 0; page_token = None
    while True:
        try:
            if tracker: tracker.check_cancel()
            res = service.files().list(q=f"'{folder_id}' in parents and trashed=false", fields="nextPageToken, files(id, name, mimeType, size, parents)", pageToken=page_token).execute()
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
            if tracker and len(files) % 10 == 0: tracker.update_scan(len(files), categories=counts)
            page_token = res.get('nextPageToken'); 
            if not page_token: break
        except: break
    return files, counts

def download_file(service, file_id, path, tracker=None):
    request = service.files().get_media(fileId=file_id)
    with io.FileIO(path, 'wb') as fh:
        downloader = MediaIoBaseDownload(fh, request)
        done = False
        while not done:
            if tracker: tracker.check_cancel()
            status, done = downloader.next_chunk()

def upload_file(service, path, name, parent_id=None):
    file_metadata = {'name': name}; 
    if parent_id: file_metadata['parents'] = [parent_id]
    media = MediaFileUpload(path, mimetype='video/mp4', resumable=True)
    return service.files().create(body=file_metadata, media_body=media, fields='id').execute()

def add_scrolling_text_logic(video_path, texts, output_path):
    font_path = os.path.join(TEMP_DIR, "LiberationSans-Bold.ttf")
    if not os.path.exists(font_path): subprocess.run(["wget", "-O", font_path, FONT_URL])
    video = VideoFileClip(video_path)
    try: font = ImageFont.truetype(font_path, 40)
    except: font = ImageFont.load_default()
    text_metrics = []
    temp_draw = ImageDraw.Draw(Image.new('RGB', (1, 1)))
    for text in texts:
        bbox = temp_draw.textbbox((0, 0), text, font=font)
        text_metrics.append({'width': bbox[2]-bbox[0], 'height': bbox[3]-bbox[1], 'text': text, 'bbox': bbox})
    def frame_filter(get_frame, t):
        frame = get_frame(t)
        if t < 5: return frame
        pil_img = Image.fromarray(frame); draw = ImageDraw.Draw(pil_img, 'RGBA')
        cycle_time = t - 5; total_cycle = (video.w + max(m['width'] for m in text_metrics)) / 40 + 30
        curr_metric = text_metrics[int(cycle_time/total_cycle) % len(text_metrics)]
        active_dur = (video.w + curr_metric['width']) / 40; time_in = cycle_time % total_cycle
        if time_in <= active_dur:
            progress = time_in / active_dur; x = int(video.w - progress * (video.w + curr_metric['width']))
            y = video.h - 32 - curr_metric['height']
            draw.rectangle([(x, y), (x+curr_metric['width']+20, y+curr_metric['height']+20)], fill=(0,0,0,220))
            draw.text((x+10, y+10-curr_metric['bbox'][1]), curr_metric['text'], font=font, fill=(255,255,255,255))
        return np.array(pil_img)
    final = video.fl(frame_filter)
    final.write_videofile(output_path, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    video.close()

def add_logo_logic(video_path, logo_path, output_path):
    video = VideoFileClip(video_path)
    logo = ImageClip(np.array(Image.open(logo_path).convert('RGBA'))).set_duration(video.duration).resize(height=int(video.h*0.07)).set_opacity(1.0).set_pos(('right','bottom'))
    CompositeVideoClip([video, logo]).write_videofile(output_path, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    video.close()

@app.route('/api/run', methods=['POST'])
def handle_run():
    data = request.json; action = data.get('action'); task_id = str(uuid.uuid4())[:8]
    def worker():
        try:
            service = get_service(data['creds'])
            if action == "copy":
                sid, did = extract_id(data['src']), extract_id(data['dst']) or 'root'
                tr = ProgressTracker(task_id, 0, "Copying", {"src": sid[:8], "dst": did[:8]})
                all_items, stats = list_recursive(service, sid, tr); tr.total = len(all_items); tr.categories = stats; tr.save()
                def clone(s_id, p_id):
                    tr.check_cancel(); m = service.files().get(fileId=s_id, fields="name").execute()
                    p_list = [p_id] if p_id != 'root' else []; nid = service.files().create(body={"name":m["name"], "mimeType":"application/vnd.google-apps.folder", "parents":p_list}, fields="id").execute()["id"]
                    tr.update(m['name'], 'application/vnd.google-apps.folder')
                    for it in service.files().list(q=f"'{s_id}' in parents and trashed=false").execute().get('files', []):
                        if it['mimeType'] == 'application/vnd.google-apps.folder': clone(it['id'], nid)
                        else: service.files().copy(fileId=it['id'], body={"name":it['name'], "parents":[nid]}).execute(); tr.update(it['name'], it['mimeType'])
                clone(sid, did); tr.complete()
            elif action == "rename":
                fid, s, r = extract_id(data['url']), data['search'], data['replace']
                tr = ProgressTracker(task_id, 0, "Renaming", {"find": s, "with": r})
                all_items, stats = list_recursive(service, fid, tr); tr.total = len(all_items); tr.categories = stats; tr.save()
                for it in all_items:
                    tr.check_cancel()
                    if s in it['name']: nn = it['name'].replace(s, r); service.files().update(fileId=it['id'], body={"name": nn}).execute(); tr.update(nn, it['mimeType'])
                    else: tr.update(it['name'], it['mimeType'], is_skipped=True)
                tr.complete()
            elif action == "count" or action == "info":
                fid = extract_id(data['url']); tr = ProgressTracker(task_id, 0, "Diagnostics", {"target": fid[:8]})
                all_items, stats = list_recursive(service, fid, tr); tr.total = len(all_items); tr.categories = stats; tr.save(); tr.complete()
            elif action == "automated":
                src = extract_id(data['url']); tr = ProgressTracker(task_id, 100, "Automated WF")
                tr.update("Cloning"); m = service.files().get(fileId=src, fields="name").execute()
                nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [UNPOSTED_FOLDER_ID]}, fields="id").execute()["id"]
                tr.update("Merging"); 
                for it in service.files().list(q=f"'{SECOND_SOURCE_FOLDER_ID}' in parents and trashed=false").execute().get('files', []): service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                tr.update("Branding"); items, _ = list_recursive(service, nid)
                for it in items:
                    tr.check_cancel()
                    if it['name'].lower().endswith('.mp4'): service.files().update(fileId=it['id'], body={"name": it['name'] + " Telegram@TechZoneX.mp4"}).execute()
                tr.complete()
            elif action == "smart_replace":
                t, s, r = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                meta = service.files().get(fileId=s, fields='size,mimeType').execute(); tr = ProgressTracker(task_id, 0, "Smart Replace", {"match": meta.get('size')})
                all_items, stats = list_recursive(service, t, tr); matches = [f for f in all_items if f.get('size') == meta.get('size')]; tr.total = len(matches); tr.save()
                for it in matches:
                    tr.check_cancel(); p = it['parents'][0] if 'parents' in it else None; service.files().delete(fileId=it['id']).execute(); service.files().copy(fileId=r, body={"name": it['name'], "parents":[p] if p else []}).execute(); tr.update(it['name'], it['mimeType'])
                tr.complete()
            elif action == "distribute":
                t, s = extract_id(data['target']), extract_id(data['source']); meta = service.files().get(fileId=s, fields='name,size').execute()
                tr = ProgressTracker(task_id, 0, "Distributing", {"file": meta['name']}); all_items, stats = list_recursive(service, t, tr)
                folders = [f for f in all_items if f['mimeType'] == 'application/vnd.google-apps.folder']; folders.insert(0, {'id': t}); tr.total = len(folders); tr.save()
                for fid in folders:
                    tr.check_cancel()
                    if not service.files().list(q=f"'{fid['id']}' in parents and size='{meta['size']}'").execute().get('files', []): service.files().copy(fileId=s, body={"name": meta['name'], "parents": [fid['id']]}).execute(); tr.update(f"Folder-{fid['id'][:5]}", "Folders")
                    else: tr.update("", "", True)
                tr.complete()
            elif action == "trim":
                fid, st, et = extract_id(data['url']), data.get('start'), data.get('end'); tr = ProgressTracker(task_id, 4, "Trimming", {"id": fid[:8]})
                io_in, io_out = os.path.join(TEMP_DIR, f"in_{task_id}.mp4"), os.path.join(TEMP_DIR, f"out_{task_id}.mp4")
                tr.temp_files = [io_in, io_out]; tr.status="Downloading"; tr.save(); download_file(service, fid, io_in, tr); tr.current=1; tr.status="Processing"; tr.save()
                subprocess.run(f"ffmpeg -i {io_in} -ss {st} -to {et} -c copy {io_out} -y", shell=True)
                tr.current=2; tr.status="Uploading"; tr.save(); upload_file(service, io_out, "Trimmed.mp4"); tr.current=4; tr.complete(status="Done", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")
            elif action == "merge":
                id1, id2 = extract_id(data['src1']), extract_id(data['src2']); tr = ProgressTracker(task_id, 5, "Merging")
                f1, f2, fout, flist = [os.path.join(TEMP_DIR, f"{x}_{task_id}.mp4") for x in ['m1','m2','mout','list']]
                tr.temp_files = [f1, f2, fout, flist]; download_file(service, id1, f1, tr); tr.current=1; tr.save(); download_file(service, id2, f2, tr); tr.current=2; tr.save()
                with open(flist, 'w') as f: f.write(f"file '{f1}'\nfile '{f2}'")
                subprocess.run(f"ffmpeg -f concat -safe 0 -i {flist} -c copy {fout} -y", shell=True)
                tr.current=3; tr.save(); upload_file(service, fout, "Merged.mp4"); tr.current=5; tr.complete(status="Done", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")
            elif action == "watermark":
                fid, wtype, wtext = extract_id(data['url']), data.get('type'), data.get('text', ""); tr = ProgressTracker(task_id, 100, "Watermarking", {"type": wtype})
                vin, vout, lin = os.path.join(TEMP_DIR, f"in_{task_id}.mp4"), os.path.join(TEMP_DIR, f"wm_{task_id}.mp4"), os.path.join(TEMP_DIR, f"lg_{task_id}.png")
                tr.temp_files = [vin, vout, lin]; tr.status="Downloading Video"; tr.save(); download_file(service, fid, vin, tr); tr.current=30
                tr.status="Rendering"; tr.save()
                if wtype == "text": add_scrolling_text_logic(vin, [t.strip() for t in wtext.split('|')] or ["@TechZoneX"], vout)
                else: download_file(service, WATERMARK_LOGO_ID, lin); add_logo_logic(vin, lin, vout)
                tr.current=80; tr.status="Uploading"; tr.save(); upload_file(service, vout, f"Watermarked_{wtype}.mp4"); tr.current=100; tr.complete(status="Done", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")
        except Exception as e:
            if "Cancelled" in str(e) or TASK_FLAGS.get(task_id): TASKS[task_id]['status'] = "Cancelled"; TASKS[task_id]['cancelled'] = True
            else: TASKS[task_id]['status'] = f"Failed: {str(e)}"
            TASKS[task_id]['is_complete'] = True
    threading.Thread(target=worker).start()
    return jsonify({"task_id": task_id})

@app.route('/api/get_duration', methods=['POST'])
def get_video_duration():
    try:
        data = request.json; meta = get_service(data['creds']).files().get(fileId=extract_id(data['url']), fields='videoMediaMetadata').execute()
        seconds = int(meta.get('videoMediaMetadata', {}).get('durationMillis', 0)) // 1000; fmt = str(datetime.timedelta(seconds=seconds))
        return jsonify({"duration": "0"+fmt if len(fmt)==7 else fmt})
    except Exception as e: return jsonify({"error": str(e)}), 500

@app.route('/')
def h(): return "OK", 200
@app.route('/api/cancel/<tid>', methods=['POST'])
def c(tid): 
    if tid in TASKS: TASK_FLAGS[tid] = True; TASKS[tid]['status'] = "Cancelling..."
    return jsonify({})
@app.route('/api/dismiss/<tid>', methods=['POST'])
def d(tid):
    if tid in TASKS:
        for f in TASKS[tid].get('temp_files', []): 
            if os.path.exists(f): os.remove(f)
        del TASKS[tid]
    if tid in TASK_FLAGS: del TASK_FLAGS[tid]
    return jsonify({})
@app.route('/api/download/<tid>', methods=['GET'])
def dl(tid):
    if tid not in TASKS: return "404", 404
    for f in TASKS[tid].get('temp_files', []):
        if os.path.exists(f) and ("wm_" in f or "trim" in f or "mout" in f or "out" in f): return send_file(f, as_attachment=True, download_name="output.mp4")
    return "404", 404
@app.route('/api/status/<tid>')
def s(tid): return jsonify(TASKS.get(tid, {"status": "Waiting", "is_complete": False}))
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
    <title>TechZoneX Drive Suite</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;500;700&display=swap');
        body { font-family: 'Space Grotesk', sans-serif; background: #030712; color: #e2e8f0; }
        .glass-panel { background: rgba(17, 24, 39, 0.7); backdrop-filter: blur(20px); border: 1px solid rgba(55, 65, 81, 0.5); border-radius: 1rem; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1); }
        input, select { background: #0f172a !important; border: 1px solid #1e293b !important; color: white !important; font-size: 0.8rem !important; }
        .show-menu { display: grid !important; }
        ::-webkit-scrollbar { width: 4px; } ::-webkit-scrollbar-thumb { background: #334155; }
    </style>
</head>
<body class="p-3 md:p-6 min-h-screen">
    <div class="max-w-7xl mx-auto space-y-6">
        <nav class="bg-slate-900/90 p-4 rounded-xl flex flex-col md:flex-row justify-between items-center gap-4 border border-slate-800 sticky top-2 z-50">
            <div class="flex items-center gap-3 w-full md:w-auto justify-between">
                <div class="flex items-center gap-3">
                    <div class="w-10 h-10 bg-blue-600 rounded-lg flex items-center justify-center text-white font-bold text-xl">TZ</div>
                    <div>
                        <h1 class="font-bold text-white text-lg leading-none">TECHZONEX</h1>
                        <div class="flex items-center gap-2">
                            <div id="status-dot" class="w-2 h-2 bg-red-500 rounded-full"></div>
                            <span id="status-text" class="text-[10px] uppercase text-slate-400 font-bold">Offline</span>
                        </div>
                    </div>
                </div>
                <button onclick="document.getElementById('quick-menu').classList.toggle('show-menu')" class="md:hidden px-3 py-2 bg-slate-800 rounded text-slate-300"><i class="fas fa-bars"></i></button>
            </div>
            <div class="flex items-center gap-3 w-full md:w-auto justify-end"><div id="auth-btn"></div></div>
            <div id="quick-menu" class="hidden md:grid grid-cols-3 md:grid-cols-5 gap-2 w-full mt-2 md:mt-0 bg-slate-950/50 p-2 rounded-lg md:bg-transparent">
                <button onclick="scrollCard('copy')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">📂 Copy</button>
                <button onclick="scrollCard('rename')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">✏️ Rename</button>
                <button onclick="scrollCard('count')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">📊 Info</button>
                <button onclick="scrollCard('auto')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">⚡ Auto</button>
                <button onclick="scrollCard('smart')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">🔄 Replace</button>
                <button onclick="scrollCard('distribute')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">📡 Distribute</button>
                <button onclick="scrollCard('trim')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">✂️ Trim</button>
                <button onclick="scrollCard('merge')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">🔗 Merge</button>
                <button onclick="scrollCard('watermark')" class="p-2 text-[10px] bg-slate-800 rounded hover:bg-slate-700 text-left">💧 Watermark</button>
            </div>
        </nav>
        <div id="monitor-panel" class="hidden">
            <div class="flex justify-between items-center mb-2 px-1">
                <h2 class="text-xs font-bold text-slate-500 uppercase tracking-widest">Active Tasks</h2>
                <button onclick="clearAll()" class="text-[10px] text-blue-400 hover:text-white">CLEAR ALL</button>
            </div>
            <div id="task-list" class="grid grid-cols-1 md:grid-cols-2 gap-4"></div>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <div id="card-copy" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-copy text-blue-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-01</span></div>
                <h3 class="font-bold text-white text-sm">Recursive Clone</h3>
                <input type="text" id="cp-src" placeholder="Source Folder ID" class="w-full p-3 rounded-lg text-sm">
                <input type="text" id="cp-dst" placeholder="Destination (Root if empty)" class="w-full p-3 rounded-lg text-sm">
                <button onclick="run('copy', {src:'cp-src', dst:'cp-dst'})" class="w-full py-3 bg-blue-600 hover:bg-blue-700 rounded-lg font-bold text-sm text-white transition">Clone Folder</button>
            </div>
            <div id="card-rename" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-i-cursor text-purple-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-02</span></div>
                <h3 class="font-bold text-white text-sm">Bulk Rename</h3>
                <input type="text" id="rn-url" placeholder="Target Folder ID" class="w-full p-3 rounded-lg text-sm">
                <div class="grid grid-cols-2 gap-2"><input type="text" id="rn-s" placeholder="Find" class="p-3 rounded-lg text-sm"><input type="text" id="rn-r" placeholder="Replace" class="p-3 rounded-lg text-sm"></div>
                <button onclick="run('rename', {url:'rn-url', search:'rn-s', replace:'rn-r'})" class="w-full py-3 bg-purple-600 hover:bg-purple-700 rounded-lg font-bold text-sm text-white transition">Rename All</button>
            </div>
            <div id="card-count" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-chart-pie text-pink-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-03</span></div>
                <h3 class="font-bold text-white text-sm">Diagnostics</h3>
                <input type="text" id="qa-url" placeholder="Folder/File ID" class="w-full p-3 rounded-lg text-sm">
                <div class="grid grid-cols-2 gap-2"><button onclick="run('count', {url:'qa-url'})" class="py-3 bg-slate-800 hover:bg-slate-700 rounded-lg text-xs font-bold text-slate-300">Count Files</button><button onclick="run('info', {url:'qa-url'})" class="py-3 bg-slate-800 hover:bg-slate-700 rounded-lg text-xs font-bold text-slate-300">Metadata</button></div>
            </div>
            <div id="card-auto" class="glass-panel p-5 space-y-3 border border-dashed border-yellow-500/30">
                <div class="flex justify-between items-center"><i class="fas fa-bolt text-yellow-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-04</span></div>
                <h3 class="font-bold text-white text-sm">Auto Workflow</h3>
                <input type="text" id="at-url" placeholder="Source Folder ID" class="w-full p-3 rounded-lg text-sm">
                <button onclick="run('automated', {url:'at-url'})" class="w-full py-3 bg-yellow-600 hover:bg-yellow-700 rounded-lg font-bold text-sm text-white transition">Execute Sequence</button>
            </div>
            <div id="card-smart" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-sync-alt text-orange-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-06</span></div>
                <h3 class="font-bold text-white text-sm">Smart Replace</h3>
                <input type="text" id="sr-target" placeholder="Target Folder" class="w-full p-3 rounded-lg text-sm">
                <div class="grid grid-cols-2 gap-2"><input type="text" id="sr-sample" placeholder="Sample File" class="p-3 rounded-lg text-sm"><input type="text" id="sr-replace" placeholder="New File" class="p-3 rounded-lg text-sm"></div>
                <button onclick="run('smart_replace', {target:'sr-target', sample:'sr-sample', replace:'sr-replace'})" class="w-full py-3 bg-orange-600 hover:bg-orange-700 rounded-lg font-bold text-sm text-white transition">Swap Matches</button>
            </div>
            <div id="card-distribute" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-network-wired text-emerald-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-07</span></div>
                <h3 class="font-bold text-white text-sm">Distribute File</h3>
                <input type="text" id="sd-target" placeholder="Root Target Folder" class="w-full p-3 rounded-lg text-sm">
                <input type="text" id="sd-src" placeholder="File to Copy" class="w-full p-3 rounded-lg text-sm">
                <button onclick="run('distribute', {target:'sd-target', source:'sd-src'})" class="w-full py-3 bg-emerald-600 hover:bg-emerald-700 rounded-lg font-bold text-sm text-white transition">Sync to Subfolders</button>
            </div>
            <div id="card-trim" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-scissors text-red-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-08</span></div>
                <h3 class="font-bold text-white text-sm">Video Trimmer</h3>
                <input type="text" id="tr-url" placeholder="Video ID" class="w-full p-3 rounded-lg text-sm" onblur="fetchDuration(this.value)">
                <div class="grid grid-cols-2 gap-2"><input type="text" id="tr-start" placeholder="00:00:00" class="p-3 rounded-lg text-sm"><input type="text" id="tr-end" placeholder="00:00:00" class="p-3 rounded-lg text-sm"></div>
                <button onclick="run('trim', {url:'tr-url', start:'tr-start', end:'tr-end'})" class="w-full py-3 bg-red-600 hover:bg-red-700 rounded-lg font-bold text-sm text-white transition">Trim & Upload</button>
            </div>
            <div id="card-merge" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-object-group text-indigo-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-09</span></div>
                <h3 class="font-bold text-white text-sm">Video Merger</h3>
                <input type="text" id="vm-1" placeholder="Video 1 ID" class="w-full p-3 rounded-lg text-sm">
                <input type="text" id="vm-2" placeholder="Video 2 ID" class="w-full p-3 rounded-lg text-sm">
                <button onclick="run('merge', {src1:'vm-1', src2:'vm-2'})" class="w-full py-3 bg-indigo-600 hover:bg-indigo-700 rounded-lg font-bold text-sm text-white transition">Merge Files</button>
            </div>
            <div id="card-watermark" class="glass-panel p-5 space-y-3">
                <div class="flex justify-between items-center"><i class="fas fa-stamp text-cyan-500"></i><span class="text-[10px] bg-slate-900 px-2 rounded text-slate-500 font-bold">OPT-10</span></div>
                <h3 class="font-bold text-white text-sm">Watermark</h3>
                <input type="text" id="wm-url" placeholder="Video ID" class="w-full p-3 rounded-lg text-sm">
                <select id="wm-type" class="w-full p-3 rounded-lg text-sm bg-slate-900 text-white"><option value="text">Scrolling Text</option><option value="image">Logo Overlay</option></select>
                <input type="text" id="wm-text" placeholder="Text (Use | for newlines)" class="w-full p-3 rounded-lg text-sm">
                <button onclick="run('watermark', {url:'wm-url', type:'wm-type', text:'wm-text'})" class="w-full py-3 bg-cyan-600 hover:bg-cyan-700 rounded-lg font-bold text-sm text-white transition">Apply Watermark</button>
            </div>
        </div>
    </div>
    <script>
        const API = "https://simple-liana-techzone3201-048a28fa.koyeb.app";
        const tasks = JSON.parse(localStorage.getItem('tasks') || '[]');
        function scrollCard(id) { document.getElementById('card-'+id).scrollIntoView({behavior:'smooth'}); document.getElementById('quick-menu').classList.remove('show-menu'); }
        async function init() {
            try { await fetch(API+'/'); document.getElementById('status-dot').className="w-2 h-2 bg-green-500 rounded-full"; document.getElementById('status-text').innerText="Online"; }
            catch { document.getElementById('status-dot').className="w-2 h-2 bg-red-500 rounded-full"; }
            const h = window.location.hash; if(h.includes('auth_data=')) { localStorage.setItem('creds', JSON.parse(decodeURIComponent(h.split('auth_data=')[1]))); window.history.replaceState(null,null,' '); location.reload(); }
            const creds = localStorage.getItem('creds');
            document.getElementById('auth-btn').innerHTML = creds ? `<button onclick="localStorage.removeItem('creds');location.reload()" class="px-4 py-2 bg-red-900/30 text-red-200 rounded-lg text-xs font-bold border border-red-500/30">LOGOUT</button>` : `<button onclick="location.href='${API}/auth/login'" class="px-4 py-2 bg-green-600 text-white rounded-lg text-xs font-bold shadow-lg shadow-green-500/20">LOGIN GOOGLE</button>`;
            tasks.forEach(track);
        }
        async function fetchDuration(url) {
            if(!url || !localStorage.getItem('creds')) return;
            document.getElementById('tr-start').value = "...";
            try { const r = await fetch(API+'/api/get_duration', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({url, creds:localStorage.getItem('creds')})}); const d = await r.json(); if(d.duration) { document.getElementById('tr-start').value="00:00:00"; document.getElementById('tr-end').value=d.duration; } } catch(e) {}
        }
        async function run(action, fields) {
            if(!localStorage.getItem('creds')) return alert("Please Login First");
            const body = {action, creds: localStorage.getItem('creds')};
            for(let k in fields) body[k] = document.getElementById(fields[k]).value;
            try { const r = await fetch(API+'/api/run', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)}); const d = await r.json(); if(!r.ok) throw new Error("Failed"); tasks.push(d.task_id); localStorage.setItem('tasks', JSON.stringify(tasks)); track(d.task_id); } catch { alert("Failed to start task. Check server status."); }
        }
        function track(id) {
            document.getElementById('monitor-panel').classList.remove('hidden'); if(document.getElementById('c-'+id)) return;
            const card = document.createElement('div'); card.id = 'c-'+id; card.className = "bg-slate-900/80 border border-slate-700 p-4 rounded-xl relative overflow-hidden"; document.getElementById('task-list').appendChild(card);
            const t = setInterval(async () => {
                try {
                    const r = await fetch(API+'/api/status/'+id); const s = await r.json();
                    let stats = ""; if(s.categories) stats = `<div class="grid grid-cols-4 gap-1 mt-2 border-t border-slate-800 pt-2">` + Object.keys(s.categories).map(k => s.categories[k]>0?`<div class="text-[9px] text-slate-400 bg-slate-950 rounded px-1 text-center">${k}<br><b class="text-white">${s.categories[k]}</b></div>`:"").join('') + `</div>`;
                    let btn = `<button onclick="fetch('${API}/api/cancel/${id}',{method:'POST'})" class="text-red-400 text-[10px] font-bold border border-red-900 px-2 py-1 rounded">CANCEL</button>`;
                    if(s.is_complete) { clearInterval(t); btn = `<div class="flex gap-2"><button onclick="dismiss('${id}')" class="text-slate-400 text-[10px] font-bold bg-slate-800 px-2 py-1 rounded">DISMISS</button>`; if(s.result_url) btn += `<a href="${s.result_url}" class="text-white text-[10px] font-bold bg-green-600 px-2 py-1 rounded">DL</a></div>`; else btn += `</div>`; }
                    card.innerHTML = `<div class="flex justify-between items-start mb-2"><div><div class="text-[10px] font-bold text-blue-400 uppercase tracking-widest">${s.action}</div><div class="text-[9px] text-slate-500">#${id}</div></div>${btn}</div><div class="text-xs font-bold text-white mb-1 truncate">${s.status}</div><div class="w-full bg-slate-950 h-1 rounded overflow-hidden"><div class="bg-blue-500 h-full transition-all duration-500" style="width:${s.percent}%"></div></div><div class="flex justify-between mt-1 text-[9px] text-slate-500"><span>${s.current}/${s.total}</span><span>${s.percent}%</span></div>${stats}`;
                } catch {}
            }, 1000);
        }
        function dismiss(id) { document.getElementById('c-'+id).remove(); const idx = tasks.indexOf(id); if(idx>-1) tasks.splice(idx,1); localStorage.setItem('tasks', JSON.stringify(tasks)); fetch(API+'/api/dismiss/'+id, {method:'POST'}); if(tasks.length===0) document.getElementById('monitor-panel').classList.add('hidden'); }
        function clearAll() { tasks.forEach(id => fetch(API+'/api/dismiss/'+id, {method:'POST'})); tasks.length=0; localStorage.setItem('tasks', '[]'); document.getElementById('task-list').innerHTML=""; document.getElementById('monitor-panel').classList.add('hidden'); }
        window.onload = init;
    </script>
</body>
</html>
EOF

# ==========================================
# 5. RUN THE SERVER
# ==========================================
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "600"]
