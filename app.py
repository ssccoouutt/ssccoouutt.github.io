import os
import json
import uuid
import time
import subprocess
import io
import datetime
import numpy as np

from flask import Flask, request, jsonify, redirect, session, send_from_directory, send_file
from flask_cors import CORS
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload

# MoviePy & PIL
from moviepy.editor import VideoFileClip, ImageClip, CompositeVideoClip
from PIL import Image, ImageDraw, ImageFont

# --- CONFIGURATION ---
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app" # YOUR KOYEB URL
FRONTEND_URL = "https://techzonex.store/drive"
TEMP_DIR = "/tmp"

# Folder/File Constants
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

# Global State
TASKS = {}
TASK_FLAGS = {}
MIME_MAP = {'application/pdf':'PDF', 'image/':'Images', 'video/':'Videos', 'audio/':'Audio', 'application/vnd.google-apps.folder':'Folders', 'application/zip':'Archives', 'text/':'Documents'}

# --- PROGRESS TRACKER ---
class ProgressTracker:
    def __init__(self, task_id, total, action, meta=None):
        self.task_id = task_id
        self.total = total
        self.current = 0
        self.skipped = 0
        self.status = "Initializing..."
        self.action = action
        self.last_file = ""
        self.categories = {} 
        self.meta = meta or {}
        self.start_time = time.time()
        self.is_complete = False
        self.cancelled = False
        self.result_url = None
        self.temp_files = []
        self.save()

    def check_cancel(self):
        if TASK_FLAGS.get(self.task_id): 
            self.cancelled = True
            self.status = "Cancelled"
            self.is_complete = True
            self.save()
            raise Exception("Task Cancelled")

    def update_scan(self, count, categories=None):
        self.check_cancel()
        self.status = "Scanning..."
        if categories: self.categories = categories
        self.save()

    def update(self, filename, mime=None, is_skipped=False):
        self.check_cancel()
        if is_skipped: self.skipped += 1
        else: self.current += 1
        self.status = "Processing..."
        self.last_file = filename
        self.save()

    def complete(self, status="Completed", result_url=None):
        if not self.cancelled:
            self.is_complete = True
            self.status = status
            if result_url: self.result_url = result_url
            self.save()

    def save(self):
        pct = 0
        if self.is_complete: pct = 100
        elif self.total > 0: pct = round(((self.current + self.skipped) / self.total * 100), 1)
        TASKS[self.task_id] = {
            "id": self.task_id, "action": self.action, "total": self.total,
            "current": self.current, "skipped": self.skipped, "remaining": max(0, self.total - (self.current + self.skipped)),
            "percent": pct, "status": self.status, "last_file": self.last_file[:40],
            "categories": self.categories, "meta": self.meta, "is_complete": self.is_complete,
            "cancelled": self.cancelled, "result_url": self.result_url
        }

# --- HELPERS ---
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
    files = []
    counts = {v: 0 for v in MIME_MAP.values()}; counts['Other'] = 0
    page_token = None
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
                    files.append(f)
                    sub_files, sub_counts = list_recursive(service, f['id'], tracker)
                    files.extend(sub_files)
                    for k, v in sub_counts.items(): counts[k] += v
                else: files.append(f)
            if tracker and len(files) % 10 == 0: tracker.update_scan(len(files), categories=counts)
            page_token = res.get('nextPageToken')
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
    file_metadata = {'name': name}
    if parent_id: file_metadata['parents'] = [parent_id]
    media = MediaFileUpload(path, mimetype='video/mp4', resumable=True)
    return service.files().create(body=file_metadata, media_body=media, fields='id').execute()

# --- WATERMARK LOGIC ---
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

# --- API ROUTES ---
@app.route('/api/run', methods=['POST'])
def handle_run():
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        try:
            service = get_service(data['creds'])
            
            # --- ACTION 1: COPY ---
            if action == "copy":
                sid, did = extract_id(data['src']), extract_id(data['dst']) or 'root'
                tr = ProgressTracker(task_id, 0, "Copying", {"src": sid[:8], "dst": did[:8]})
                all_items, stats = list_recursive(service, sid, tr)
                tr.total = len(all_items); tr.categories = stats; tr.save()
                
                def clone(s_id, p_id):
                    tr.check_cancel()
                    m = service.files().get(fileId=s_id, fields="name").execute()
                    p_list = [p_id] if p_id != 'root' else []
                    nid = service.files().create(body={"name":m["name"], "mimeType":"application/vnd.google-apps.folder", "parents":p_list}, fields="id").execute()["id"]
                    tr.update(m['name'], 'application/vnd.google-apps.folder')
                    for it in service.files().list(q=f"'{s_id}' in parents and trashed=false").execute().get('files', []):
                        if it['mimeType'] == 'application/vnd.google-apps.folder': clone(it['id'], nid)
                        else:
                            service.files().copy(fileId=it['id'], body={"name":it['name'], "parents":[nid]}).execute()
                            tr.update(it['name'], it['mimeType'])
                clone(sid, did)
                tr.complete()

            # --- ACTION 2: RENAME ---
            elif action == "rename":
                fid, s, r = extract_id(data['url']), data['search'], data['replace']
                tr = ProgressTracker(task_id, 0, "Renaming", {"find": s, "with": r})
                all_items, stats = list_recursive(service, fid, tr)
                tr.total = len(all_items); tr.categories = stats; tr.save()
                for it in all_items:
                    tr.check_cancel()
                    if s in it['name']:
                        nn = it['name'].replace(s, r)
                        service.files().update(fileId=it['id'], body={"name": nn}).execute()
                        tr.update(nn, it['mimeType'])
                    else: tr.update(it['name'], it['mimeType'], is_skipped=True)
                tr.complete()

            # --- ACTION 3: COUNT/INFO ---
            elif action == "count" or action == "info":
                fid = extract_id(data['url'])
                tr = ProgressTracker(task_id, 0, "Diagnostics", {"target": fid[:8]})
                all_items, stats = list_recursive(service, fid, tr)
                tr.total = len(all_items); tr.categories = stats; tr.save()
                tr.complete()

            # --- ACTION 4: AUTOMATED ---
            elif action == "automated":
                src = extract_id(data['url'])
                tr = ProgressTracker(task_id, 100, "Automated WF")
                tr.update("Cloning Source"); m = service.files().get(fileId=src, fields="name").execute()
                nid = service.files().create(body={"name": m["name"], "mimeType": "application/vnd.google-apps.folder", "parents": [UNPOSTED_FOLDER_ID]}, fields="id").execute()["id"]
                tr.update("Merging Source 2"); 
                for it in service.files().list(q=f"'{SECOND_SOURCE_FOLDER_ID}' in parents and trashed=false").execute().get('files', []):
                    service.files().copy(fileId=it['id'], body={"name": it['name'], "parents": [nid]}).execute()
                tr.update("Branding")
                items, _ = list_recursive(service, nid)
                for it in items:
                    tr.check_cancel()
                    if it['name'].lower().endswith('.mp4'):
                        service.files().update(fileId=it['id'], body={"name": it['name'] + " Telegram@TechZoneX.mp4"}).execute()
                tr.complete()

            # --- ACTION 6: SMART REPLACE ---
            elif action == "smart_replace":
                t, s, r = extract_id(data['target']), extract_id(data['sample']), extract_id(data['replace'])
                meta = service.files().get(fileId=s, fields='size,mimeType').execute()
                tr = ProgressTracker(task_id, 0, "Smart Replace", {"match": meta.get('size')})
                all_items, stats = list_recursive(service, t, tr)
                matches = [f for f in all_items if f.get('size') == meta.get('size')]
                tr.total = len(matches); tr.save()
                for it in matches:
                    tr.check_cancel()
                    p = it['parents'][0] if 'parents' in it else None
                    service.files().delete(fileId=it['id']).execute()
                    service.files().copy(fileId=r, body={"name": it['name'], "parents":[p] if p else []}).execute()
                    tr.update(it['name'], it['mimeType'])
                tr.complete()

            # --- ACTION 7: DISTRIBUTE ---
            elif action == "distribute":
                t, s = extract_id(data['target']), extract_id(data['source'])
                meta = service.files().get(fileId=s, fields='name,size').execute()
                tr = ProgressTracker(task_id, 0, "Distributing", {"file": meta['name']})
                all_items, stats = list_recursive(service, t, tr)
                folders = [f for f in all_items if f['mimeType'] == 'application/vnd.google-apps.folder']
                folders.insert(0, {'id': t})
                tr.total = len(folders); tr.save()
                for fid in folders:
                    tr.check_cancel()
                    if not service.files().list(q=f"'{fid['id']}' in parents and size='{meta['size']}'").execute().get('files', []):
                        service.files().copy(fileId=s, body={"name": meta['name'], "parents": [fid['id']]}).execute()
                        tr.update(f"Folder-{fid['id'][:5]}", "Folders")
                    else: tr.update("", "", True)
                tr.complete()

            # --- ACTION 8: TRIM ---
            elif action == "trim":
                fid, st, et = extract_id(data['url']), data.get('start'), data.get('end')
                tr = ProgressTracker(task_id, 4, "Trimming", {"id": fid[:8]})
                io_in, io_out = os.path.join(TEMP_DIR, f"in_{task_id}.mp4"), os.path.join(TEMP_DIR, f"out_{task_id}.mp4")
                tr.temp_files = [io_in, io_out]; tr.status="Downloading"; tr.save()
                download_file(service, fid, io_in, tr); tr.current=1; tr.status="Processing"; tr.save()
                subprocess.run(f"ffmpeg -i {io_in} -ss {st} -to {et} -c copy {io_out} -y", shell=True)
                tr.current=2; tr.status="Uploading"; tr.save()
                upload_file(service, io_out, "Trimmed.mp4"); tr.current=4
                tr.complete(status="Done", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")

            # --- ACTION 9: MERGE ---
            elif action == "merge":
                id1, id2 = extract_id(data['src1']), extract_id(data['src2'])
                tr = ProgressTracker(task_id, 5, "Merging")
                f1, f2, fout, flist = [os.path.join(TEMP_DIR, f"{x}_{task_id}.mp4") for x in ['m1','m2','mout','list']]
                tr.temp_files = [f1, f2, fout, flist]
                download_file(service, id1, f1, tr); tr.current=1; tr.save()
                download_file(service, id2, f2, tr); tr.current=2; tr.save()
                with open(flist, 'w') as f: f.write(f"file '{f1}'\nfile '{f2}'")
                subprocess.run(f"ffmpeg -f concat -safe 0 -i {flist} -c copy {fout} -y", shell=True)
                tr.current=3; tr.save(); upload_file(service, fout, "Merged.mp4")
                tr.current=5; tr.complete(status="Done", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")

            # --- ACTION 10: WATERMARK ---
            elif action == "watermark":
                fid, wtype, wtext = extract_id(data['url']), data.get('type'), data.get('text', "")
                tr = ProgressTracker(task_id, 100, "Watermarking", {"type": wtype})
                vin, vout, lin = os.path.join(TEMP_DIR, f"in_{task_id}.mp4"), os.path.join(TEMP_DIR, f"wm_{task_id}.mp4"), os.path.join(TEMP_DIR, f"lg_{task_id}.png")
                tr.temp_files = [vin, vout, lin]
                tr.status="Downloading Video"; tr.save(); download_file(service, fid, vin, tr); tr.current=30
                tr.status="Rendering"; tr.save()
                if wtype == "text":
                    add_scrolling_text_logic(vin, [t.strip() for t in wtext.split('|')] or ["@TechZoneX"], vout)
                else:
                    download_file(service, WATERMARK_LOGO_ID, lin)
                    add_logo_logic(vin, lin, vout)
                tr.current=80; tr.status="Uploading"; tr.save()
                upload_file(service, vout, f"Watermarked_{wtype}.mp4"); tr.current=100
                tr.complete(status="Done", result_url=f"{SERVER_DOMAIN}/api/download/{task_id}")

        except Exception as e:
            if "Cancelled" in str(e) or TASK_FLAGS.get(task_id): TASKS[task_id]['status'] = "Cancelled"; TASKS[task_id]['cancelled'] = True
            else: TASKS[task_id]['status'] = f"Failed: {str(e)}"
            TASKS[task_id]['is_complete'] = True

    threading.Thread(target=worker).start()
    return jsonify({"task_id": task_id})

@app.route('/api/get_duration', methods=['POST'])
def get_video_duration():
    try:
        data = request.json
        meta = get_service(data['creds']).files().get(fileId=extract_id(data['url']), fields='videoMediaMetadata').execute()
        seconds = int(meta.get('videoMediaMetadata', {}).get('durationMillis', 0)) // 1000
        fmt = str(datetime.timedelta(seconds=seconds))
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
        if os.path.exists(f) and ("wm_" in f or "trim" in f or "mout" in f or "out" in f):
            return send_file(f, as_attachment=True, download_name="output.mp4")
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
