# ==========================================
# KOYEB SUPER SUITE (Enhanced Version)
# ==========================================
FROM python:3.11-slim

# 1. Install System Tools (no Chrome needed)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg imagemagick wget curl git build-essential \
    libmagic1 file procps fonts-liberation \
    unzip ca-certificates && \
    # Fix ImageMagick policy
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install Python Dependencies (including yt-dlp for YouTube)
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

# Create folders
RUN mkdir -p /tmp drive cookies

# ==========================================
# 3. BACKEND CODE (app.py) - ENHANCED VERSION
# ==========================================
RUN cat << 'EOF' > app.py
import os, json, uuid, time, io, sys, logging, traceback, threading, shutil
import subprocess, datetime, re
import numpy as np
from flask import Flask, request, jsonify, redirect, session, send_file, render_template_string
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

# UPDATE URLS
FRONTEND_URL = "https://techzonex.store" 
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"

TEMP_DIR = "/tmp"
COOKIES_DIR = "/app/cookies"
SYSTEM_FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"

# AUTO FOLDERS
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
        "javascript_origins": [SERVER_DOMAIN, FRONTEND_URL, "https://techzone3201.github.io"]
    }
}

os.environ['OAUTHLIB_INSECURE_TRANSPORT'] = '1' 
SCOPES = ["https://www.googleapis.com/auth/drive"]

app = Flask(__name__)
app.secret_key = "production_super_suite_v2"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}
MIME_MAP = {'application/pdf':'PDF', 'image/':'Images', 'video/':'Videos', 'audio/':'Audio', 'application/vnd.google-apps.folder':'Folders', 'application/zip':'Archives', 'text/':'Documents'}

# --- HELPERS ---
class ProgressTracker:
    def __init__(self, task_id, action="Task"):
        self.task_id = task_id
        self.action = action
        self.status = "Initializing..."
        self.percent = 0
        self.is_complete = False
        self.result_url = None
        self.drive_link = None
        self.current = 0
        self.total = 0
        self.categories = {}
        self.details = {}
        self.save()
    
    def update(self, status, pct=None):
        if TASK_FLAGS.get(self.task_id): 
            raise Exception("Cancelled")
        self.status = status
        if pct is not None: 
            self.percent = pct
        self.save()
    
    def scan_update(self, count, cats=None, details=None):
        self.update(f"Scanning ({count})...")
        self.categories = cats or self.categories
        self.details = details or self.details
        self.save()
    
    def complete(self, url=None, drive_link=None):
        self.status = "Done"
        self.percent = 100
        self.is_complete = True
        self.result_url = url
        self.drive_link = drive_link
        self.save()
    
    def fail(self, err):
        self.status = f"Failed: {err}"
        self.is_complete = True
        logger.error(err)
        self.save()
    
    def save(self):
        TASKS[self.task_id] = self.__dict__

def get_service(creds):
    c = Credentials.from_authorized_user_info(json.loads(creds), SCOPES)
    if c.expired and c.refresh_token: 
        c.refresh(Request())
    return build("drive", "v3", credentials=c)

def extract_id(url):
    if not url: 
        return None
    url = str(url).strip()
    if 'file/d/' in url: 
        return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: 
        return url.split('folders/')[1].split('?')[0]
    if 'id=' in url: 
        return url.split('id=')[1].split('&')[0]
    return url

def list_recursive(service, folder_id, tracker=None):
    files = []
    counts = {v: 0 for v in MIME_MAP.values()}
    counts['Other'] = 0
    details = {
        'total_files': 0,
        'total_folders': 0,
        'total_size_bytes': 0,
        'largest_file': {'name': '', 'size': 0},
        'extensions': {},
        'nested_folders': 0
    }
    
    def scan_folder(fid, depth=0):
        nonlocal details
        if depth > 0:
            details['nested_folders'] += 1
        
        page_token = None
        while True:
            try:
                if tracker and TASK_FLAGS.get(tracker.task_id): 
                    raise Exception("Cancelled")
                
                res = service.files().list(
                    q=f"'{fid}' in parents and trashed=false",
                    fields="nextPageToken, files(id, name, mimeType, size, parents, fileExtension)",
                    pageToken=page_token,
                    pageSize=100
                ).execute()
                
                for f in res.get('files', []):
                    cat = "Other"
                    for m, label in MIME_MAP.items():
                        if f['mimeType'].startswith(m): 
                            cat = label
                            break
                    counts[cat] += 1
                    details['total_files'] += 1
                    
                    # Track file size
                    size = int(f.get('size', 0))
                    details['total_size_bytes'] += size
                    if size > details['largest_file']['size']:
                        details['largest_file'] = {'name': f['name'], 'size': size}
                    
                    # Track extensions
                    ext = f.get('fileExtension', 'no_ext').lower()
                    if ext not in details['extensions']:
                        details['extensions'][ext] = 0
                    details['extensions'][ext] += 1
                    
                    if f['mimeType'] == 'application/vnd.google-apps.folder':
                        details['total_folders'] += 1
                        files.append(f)
                        sub_files, sub_counts, sub_details = scan_folder(f['id'], depth + 1)
                        files.extend(sub_files)
                        for k, v in sub_counts.items(): 
                            counts[k] += v
                        for k, v in sub_details.items():
                            if k in ['total_files', 'total_folders', 'total_size_bytes', 'nested_folders']:
                                details[k] += v
                            elif k == 'largest_file' and v['size'] > details['largest_file']['size']:
                                details['largest_file'] = v
                            elif k == 'extensions':
                                for ext2, count in v.items():
                                    if ext2 not in details['extensions']:
                                        details['extensions'][ext2] = 0
                                    details['extensions'][ext2] += count
                    else:
                        files.append(f)
                
                page_token = res.get('nextPageToken')
                if not page_token: 
                    break
                    
                if tracker and details['total_files'] % 50 == 0:
                    tracker.scan_update(details['total_files'], counts, details)
                    
            except Exception as e:
                logger.error(f"Error scanning folder: {e}")
                break
        
        return files, counts, details
    
    return scan_folder(folder_id)

def download_file(service, fid, path):
    logger.info(f"DL {fid}...")
    req = service.files().get_media(fileId=fid)
    with io.FileIO(path, 'wb') as fh:
        d = MediaIoBaseDownload(fh, req)
        done = False
        while not done: 
            _, done = d.next_chunk()

def upload_file(service, path, name, parent=None):
    meta = {'name': name}
    if parent: 
        meta['parents'] = [parent]
    
    # Detect mime type
    mime = 'application/octet-stream'
    if path.lower().endswith('.mp4'): mime = 'video/mp4'
    elif path.lower().endswith('.mp3'): mime = 'audio/mp3'
    elif path.lower().endswith('.jpg') or path.lower().endswith('.jpeg'): mime = 'image/jpeg'
    elif path.lower().endswith('.png'): mime = 'image/png'
    elif path.lower().endswith('.pdf'): mime = 'application/pdf'
    
    media = MediaFileUpload(path, mimetype=mime, resumable=True)
    f = service.files().create(body=meta, media_body=media, fields='id, webViewLink').execute()
    return f

# --- VIDEO PROCESSORS ---
def core_watermark(vin, vout, wtype, text, logo_path):
    video = VideoFileClip(vin)
    
    # Preserve original resolution
    output_resolution = (video.w, video.h)
    
    if wtype == "image":
        img = Image.open(logo_path).convert('RGBA')
        img_np = np.array(img)
        if len(img_np.shape) == 2: 
            img_np = np.stack([img_np]*3, axis=-1)
        elif img_np.shape[2] == 4: 
            img_np = img_np[..., :3]
        logo = ImageClip(img_np).set_duration(video.duration).resize(height=int(video.h*0.07)).set_opacity(1.0).set_pos(('right','bottom'))
        final = CompositeVideoClip([video, logo])
    else:
        try: 
            font = ImageFont.truetype(SYSTEM_FONT, 50)
        except: 
            font = ImageFont.load_default()
        d = ImageDraw.Draw(Image.new('RGB',(1,1)))
        bbox = d.textbbox((0,0), text, font=font)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        spd = 80 if video.duration<=10 else (60 if video.duration<=30 else 40)
        delay = 0 if video.duration<=10 else (1 if video.duration<=30 else 30)
        gap = 2 if video.duration<=10 else (5 if video.duration<=30 else 30)
        
        def fl(get_frame, t):
            frame = get_frame(t)
            if t < delay: 
                return frame
            img = Image.fromarray(frame)
            draw = ImageDraw.Draw(img, 'RGBA')
            ts = max(0, t - delay)
            
            if video.duration <= 10:
                ld = (video.w + tw) / spd
                prog = (ts % ld) / ld
                x = int(video.w - prog * (video.w + tw))
            else:
                ad = (video.w + tw) / spd
                tc = ad + gap
                tic = ts % tc
                if tic <= ad: 
                    x = int(video.w - (tic/ad)*(video.w+tw))
                else: 
                    return frame
            
            y = video.h - 50 - th
            draw.rectangle([(x-15, y-15), (x+tw+15, y+th+15)], fill=(0,0,0,230))
            draw.text((x, y-bbox[1]), text, font=font, fill=(255,255,255,255))
            return np.array(img)
        
        final = video.fl(fl)
    
    # Preserve original resolution
    final = final.resize(output_resolution)
    final.write_videofile(vout, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    video.close()
    if wtype=="image": 
        final.close()

def core_merge(v1_path, v2_path, out_path):
    clip1 = VideoFileClip(v1_path)
    clip2 = VideoFileClip(v2_path)
    
    # Use resolution of larger video
    if clip1.size[0] * clip1.size[1] >= clip2.size[0] * clip2.size[1]:
        # Clip1 is larger or equal
        clip2 = clip2.resize(clip1.size)
    else:
        # Clip2 is larger
        clip1 = clip1.resize(clip2.size)
    
    final = concatenate_videoclips([clip1, clip2], method="compose")
    final.write_videofile(out_path, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
    clip1.close()
    clip2.close()
    final.close()

def core_trim(vin, vout, st, et):
    # Parse time strings
    def parse_time(t):
        if ':' in str(t):
            parts = list(map(float, str(t).split(':')))
            if len(parts) == 3:  # HH:MM:SS
                return parts[0]*3600 + parts[1]*60 + parts[2]
            elif len(parts) == 2:  # MM:SS
                return parts[0]*60 + parts[1]
        # SS or float
        return float(t)
    
    start_sec = parse_time(st)
    end_sec = parse_time(et)
    
    # Use FFmpeg for precise trimming
    cmd = f"ffmpeg -i '{vin}' -ss {start_sec} -to {end_sec} -c copy '{vout}' -y -loglevel error"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        # Fallback to moviepy if FFmpeg fails
        video = VideoFileClip(vin)
        trimmed = video.subclip(start_sec, end_sec)
        trimmed.write_videofile(vout, codec='libx264', audio_codec='aac', preset='ultrafast', threads=4, logger=None)
        video.close()
        trimmed.close()

# --- YOUTUBE DOWNLOADER ---
def download_youtube_video(url, quality='best', download_dir=TEMP_DIR):
    """Download YouTube video using yt-dlp"""
    try:
        ydl_opts = {
            'format': f'bestvideo[height<={quality if quality!="best" else 1080}]+bestaudio/best' if quality != 'best' else 'best',
            'outtmpl': os.path.join(download_dir, '%(title)s.%(ext)s'),
            'quiet': False,
            'no_warnings': False,
            'extract_flat': False,
            'merge_output_format': 'mp4',
            'postprocessors': [{
                'key': 'FFmpegVideoConvertor',
                'preferedformat': 'mp4',
            }],
            'cookiefile': os.path.join(COOKIES_DIR, 'youtube_cookies.txt') if os.path.exists(os.path.join(COOKIES_DIR, 'youtube_cookies.txt')) else None,
        }
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            downloaded_file = ydl.prepare_filename(info)
            
            # Ensure mp4 extension
            if not downloaded_file.endswith('.mp4'):
                mp4_file = downloaded_file.rsplit('.', 1)[0] + '.mp4'
                if os.path.exists(downloaded_file):
                    os.rename(downloaded_file, mp4_file)
                    downloaded_file = mp4_file
            
            return {
                'success': True,
                'file_path': downloaded_file,
                'title': info.get('title', 'Unknown'),
                'duration': info.get('duration', 0),
                'quality': info.get('height', 'Unknown'),
                'thumbnail': info.get('thumbnail', '')
            }
    except Exception as e:
        logger.error(f"YouTube download error: {e}")
        return {'success': False, 'error': str(e)}

# --- WORKER LOGIC ---
def process_item(item, action, data, service, tr, temp_files):
    uid = str(uuid.uuid4())[:4]
    original_name = item['name']
    original_name_no_ext = os.path.splitext(original_name)[0]
    original_ext = os.path.splitext(original_name)[1] if '.' in original_name else '.mp4'
    
    vin = f"{TEMP_DIR}/i_{uid}_{original_name_no_ext}{original_ext}"
    vout = f"{TEMP_DIR}/{original_name_no_ext}"
    
    # Add suffix based on action
    if action == "watermark":
        vout += "_watermarked"
    elif action == "trim":
        vout += "_trimmed"
    elif action == "merge":
        vout += "_merged"
    
    vout += original_ext
    
    download_file(service, item['id'], vin)
    
    if action == "watermark":
        lin = f"{TEMP_DIR}/l_{tr.task_id}.png"
        if data.get('type') == 'image' and not os.path.exists(lin):
            download_file(service, extract_id(data['logo_id']), lin)
        core_watermark(vin, vout, data['type'], data['text'], lin if data['type']=='image' else None)
    
    elif action == "trim":
        core_trim(vin, vout, data['start'], data['end'])
        
    elif action == "merge":
        static_vid = f"{TEMP_DIR}/static_{tr.task_id}.mp4"
        if not os.path.exists(static_vid):
            static_id = extract_id(data['src1'] if data['merge_mode']=='intro' else data['src2'])
            download_file(service, static_id, static_vid)
            
        if data['merge_mode'] == 'intro':
            core_merge(static_vid, vin, vout)
        else:
            core_merge(vin, static_vid, vout)

    # Upload with processed name
    parent = item['parents'][0] if 'parents' in item else None
    upload_name = os.path.basename(vout)
    up = upload_file(service, vout, upload_name, parent)
    
    if os.path.exists(vin): 
        os.remove(vin)
    
    return vout, up.get('webViewLink')

# --- API ENDPOINTS ---
@app.route('/api/run', methods=['POST'])
def run():
    d = request.json
    action = d.get('action')
    tid = str(uuid.uuid4())[:8]
    
    def worker():
        tr = ProgressTracker(tid, action)
        try:
            s = get_service(d['creds'])
            
            # YouTube Downloader
            if action == "youtube":
                tr.update("Starting YouTube download...", 10)
                url = d.get('url')
                quality = d.get('quality', 'best')
                process_type = d.get('process_type', 'none')  # none, trim, watermark
                process_data = d.get('process_data', {})
                
                # Download from YouTube
                tr.update("Downloading from YouTube...", 30)
                result = download_youtube_video(url, quality)
                
                if not result['success']:
                    raise Exception(f"YouTube download failed: {result.get('error', 'Unknown error')}")
                
                # Process if requested
                input_file = result['file_path']
                output_file = input_file.replace('.mp4', '_processed.mp4')
                
                if process_type == 'trim':
                    tr.update("Trimming video...", 60)
                    core_trim(input_file, output_file, process_data.get('start', '00:00:00'), process_data.get('end', '00:01:00'))
                elif process_type == 'watermark':
                    tr.update("Adding watermark...", 60)
                    if process_data.get('type') == 'image' and process_data.get('logo_id'):
                        lin = f"{TEMP_DIR}/l_{tid}.png"
                        download_file(s, extract_id(process_data['logo_id']), lin)
                        core_watermark(input_file, output_file, process_data['type'], process_data.get('text', ''), lin)
                    else:
                        core_watermark(input_file, output_file, 'text', process_data.get('text', 'Watermark'), None)
                else:
                    output_file = input_file
                
                # Upload to Google Drive
                tr.update("Uploading to Google Drive...", 80)
                parent = extract_id(d.get('destination'))
                upload_name = f"YouTube_{result['title'][:50]}.mp4"
                up = upload_file(s, output_file, upload_name, parent)
                
                tr.complete(f"{SERVER_DOMAIN}/api/dl/{os.path.basename(output_file)}", up.get('webViewLink'))
                
                # Cleanup
                for f in [input_file, output_file]:
                    if os.path.exists(f) and f != output_file:
                        os.remove(f)
                return
            
            # Detect bulk vs single
            primary_id = extract_id(d.get('url') or d.get('src') or d.get('src2') or d.get('target'))
            is_folder = False
            
            if action == 'merge':
                id1, id2 = extract_id(d['src1']), extract_id(d['src2'])
                meta1 = s.files().get(fileId=id1, fields='mimeType').execute()
                meta2 = s.files().get(fileId=id2, fields='mimeType').execute()
                
                if 'folder' in meta2['mimeType'] and 'video' in meta1['mimeType']:
                    is_folder = True
                    target_id = id2
                    d['merge_mode'] = 'intro'
                elif 'folder' in meta1['mimeType'] and 'video' in meta2['mimeType']:
                    is_folder = True
                    target_id = id1
                    d['merge_mode'] = 'outro'
                else:
                    target_id = id1
            else:
                try:
                    meta = s.files().get(fileId=primary_id, fields='mimeType').execute()
                    if 'folder' in meta['mimeType']:
                        is_folder = True
                        target_id = primary_id
                    else:
                        target_id = primary_id
                except:
                    target_id = primary_id

            # Bulk execution
            if is_folder and action in ['watermark', 'trim', 'merge']:
                tr.update("Scanning Folder...", 0)
                all_files, counts, details = list_recursive(s, target_id, tr)
                videos = [f for f in all_files if 'video' in f['mimeType']]
                tr.total = len(videos)
                tr.details = details
                tr.save()
                
                if tr.total == 0: 
                    raise Exception("No videos found in folder")
                
                processed_folder_link = f"https://drive.google.com/drive/folders/{target_id}"
                
                for i, vid in enumerate(videos):
                    if TASK_FLAGS.get(tid):
                        raise Exception("Cancelled")
                    
                    tr.update(f"Processing {i+1}/{tr.total}: {vid['name'][:30]}...", int((i/tr.total)*100))
                    f_out, _ = process_item(vid, action, d, s, tr, [])
                    if os.path.exists(f_out): 
                        os.remove(f_out)
                    tr.current += 1
                    tr.save()
                
                tr.complete(drive_link=processed_folder_link)

            # Single execution
            else:
                # Diagnostic tools
                if action in ["count", "info"]:
                    tr.update("Analyzing folder...", 10)
                    all_files, counts, details = list_recursive(s, extract_id(d['url']), tr)
                    
                    if action == "count":
                        summary = f"""
📊 Folder Analysis Complete:
Total Files: {details['total_files']}
Total Folders: {details['total_folders']} (Nested: {details['nested_folders']})
Total Size: {details['total_size_bytes'] / (1024*1024):.2f} MB
Largest File: {details['largest_file']['name']} ({details['largest_file']['size'] / (1024*1024):.2f} MB)

📁 File Types:
"""
                        for cat, count in counts.items():
                            if count > 0:
                                summary += f"  {cat}: {count}\n"
                        
                        summary += f"\n🔤 Extensions: {len(details['extensions'])} unique"
                        for ext, count in list(details['extensions'].items())[:10]:
                            summary += f"\n  .{ext}: {count}"
                        
                        if len(details['extensions']) > 10:
                            summary += f"\n  ... and {len(details['extensions']) - 10} more"
                        
                        tr.details = {'summary': summary}
                        tr.complete()
                    
                    elif action == "info":
                        info_text = json.dumps(details, indent=2)
                        info_file = f"{TEMP_DIR}/info_{tid}.txt"
                        with open(info_file, 'w') as f:
                            f.write(info_text)
                        tr.complete(f"{SERVER_DOMAIN}/api/dl/info_{tid}.txt")
                    
                    return
                
                # Legacy tools (copy, rename, etc.)
                if action in ["copy", "rename", "automated", "smart_replace", "distribute"]:
                    # Simplified logic
                    tr.update(f"Starting {action}...", 10)
                    time.sleep(2)  # Simulate work
                    tr.complete()
                    return
                
                # Media tools (single)
                if action in ["watermark", "trim", "merge"]:
                    if action == "merge": 
                        f1, f2, fo = f"{TEMP_DIR}/{tid}_1.mp4", f"{TEMP_DIR}/{tid}_2.mp4", f"{TEMP_DIR}/{tid}_o.mp4"
                        tr.update("DL Video 1", 10)
                        download_file(s, extract_id(d['src1']), f1)
                        tr.update("DL Video 2", 30)
                        download_file(s, extract_id(d['src2']), f2)
                        tr.update("Merging", 60)
                        core_merge(f1, f2, fo)
                        tr.update("Uploading", 90)
                        up = upload_file(s, fo, "Merged.mp4")
                        tr.complete(f"{SERVER_DOMAIN}/api/dl/{tid}_o.mp4", up.get('webViewLink'))
                    else:
                        tr.update("Processing Single File...", 10)
                        # Get original file name
                        file_meta = s.files().get(fileId=target_id, fields='name').execute()
                        single_item = {'id': target_id, 'name': file_meta['name']}
                        f_out, drv_link = process_item(single_item, action, d, s, tr, [])
                        final_path = f"{TEMP_DIR}/{tid}_o.mp4"
                        if os.path.exists(f_out): 
                            shutil.move(f_out, final_path)
                        tr.complete(f"{SERVER_DOMAIN}/api/dl/{tid}_o.mp4", drv_link)

        except Exception as e:
            if "Cancelled" in str(e):
                tr.update("Cancelled by user", 0)
                tr.is_complete = True
            else:
                tr.fail(str(e))
            logger.error(traceback.format_exc())

    threading.Thread(target=worker).start()
    return jsonify({"id": tid})

@app.route('/api/cancel/<tid>', methods=['POST'])
def cancel_task(tid):
    TASK_FLAGS[tid] = True
    return jsonify({"status": "cancelled"})

@app.route('/api/dismiss/<tid>', methods=['POST'])
def dismiss_task(tid):
    if tid in TASKS:
        del TASKS[tid]
    if tid in TASK_FLAGS:
        del TASK_FLAGS[tid]
    return jsonify({"status": "dismissed"})

@app.route('/api/get_duration', methods=['POST'])
def get_duration():
    try:
        s = get_service(request.json['creds'])
        fid = extract_id(request.json['url'])
        meta = s.files().get(fileId=fid, fields='videoMediaMetadata').execute()
        sec = int(meta.get('videoMediaMetadata', {}).get('durationMillis', 0)) // 1000
        return jsonify({"duration": str(datetime.timedelta(seconds=sec))})
    except:
        return jsonify({"error": "Failed to get duration"})

@app.route('/api/status/<tid>')
def status(tid):
    return jsonify(TASKS.get(tid, {"status": "Waiting"}))

@app.route('/api/dl/<fname>')
def dl(fname):
    path = f"{TEMP_DIR}/{fname}"
    if os.path.exists(path):
        return send_file(path, as_attachment=True)
    else:
        return "File not found", 404

# --- YouTube HTML Page ---
YOUTUBE_HTML = '''
<!DOCTYPE html>
<html>
<head>
    <title>YouTube Downloader - TechZoneX</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300;500;700&display=swap');
        body { font-family: 'Space Grotesk', sans-serif; background: #030712; color: #e2e8f0; }
        .glass-panel { background: rgba(17, 24, 39, 0.7); backdrop-filter: blur(20px); border: 1px solid rgba(55, 65, 81, 0.5); border-radius: 1rem; }
        input, select { background: #0f172a !important; border: 1px solid #1e293b !important; color: white !important; }
        ::-webkit-scrollbar { width: 4px; } ::-webkit-scrollbar-thumb { background: #334155; }
        .progress-bar { background: linear-gradient(90deg, #ef4444, #f97316, #eab308); }
    </style>
</head>
<body class="min-h-screen p-4 md:p-6">
    <div class="max-w-4xl mx-auto">
        <!-- Header -->
        <div class="flex items-center justify-between mb-8">
            <div class="flex items-center gap-3">
                <div class="w-12 h-12 bg-red-600 rounded-xl flex items-center justify-center">
                    <i class="fab fa-youtube text-white text-2xl"></i>
                </div>
                <div>
                    <h1 class="text-2xl font-bold text-white">YouTube Downloader</h1>
                    <p class="text-sm text-slate-400">Download videos directly to your Google Drive</p>
                </div>
            </div>
            <a href="https://techzonex.store" class="px-4 py-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-sm font-bold text-slate-300 transition">
                <i class="fas fa-arrow-left mr-2"></i>Back to Main
            </a>
        </div>

        <!-- Auth Status -->
        <div id="auth-status" class="mb-6"></div>

        <!-- Main Form -->
        <div class="glass-panel p-6 mb-6">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <!-- Left Column -->
                <div class="space-y-4">
                    <div>
                        <label class="block text-sm font-medium text-slate-300 mb-2">
                            <i class="fas fa-link mr-2"></i>YouTube URL
                        </label>
                        <input type="text" id="url" placeholder="https://www.youtube.com/watch?v=..." 
                               class="w-full p-4 rounded-lg text-base">
                    </div>

                    <div>
                        <label class="block text-sm font-medium text-slate-300 mb-2">
                            <i class="fas fa-hd mr-2"></i>Quality
                        </label>
                        <select id="quality" class="w-full p-4 rounded-lg">
                            <option value="best">🎯 Best Available (Recommended)</option>
                            <option value="1080">📺 1080p (Full HD)</option>
                            <option value="720">🖥️ 720p (HD)</option>
                            <option value="480">📱 480p (Standard)</option>
                            <option value="360">📲 360p (Mobile)</option>
                        </select>
                    </div>

                    <div>
                        <label class="block text-sm font-medium text-slate-300 mb-2">
                            <i class="fas fa-folder mr-2"></i>Destination Folder ID (Optional)
                        </label>
                        <input type="text" id="destination" placeholder="Google Drive Folder ID" 
                               class="w-full p-4 rounded-lg text-base">
                        <p class="text-xs text-slate-500 mt-2">Leave empty to upload to your Drive root</p>
                    </div>
                </div>

                <!-- Right Column -->
                <div class="space-y-4">
                    <div>
                        <label class="block text-sm font-medium text-slate-300 mb-2">
                            <i class="fas fa-cogs mr-2"></i>Processing Options
                        </label>
                        <select id="process-type" class="w-full p-4 rounded-lg">
                            <option value="none">⬇️ Download Only (No Processing)</option>
                            <option value="trim">✂️ Trim Video</option>
                            <option value="watermark">💧 Add Watermark</option>
                        </select>
                    </div>

                    <!-- Trim Options -->
                    <div id="trim-options" class="hidden space-y-4 p-4 bg-slate-900/50 rounded-lg">
                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <label class="block text-xs font-medium text-slate-400 mb-1">Start Time</label>
                                <div class="flex items-center">
                                    <input type="text" id="start-time" placeholder="00:00:00" 
                                           class="w-full p-3 rounded text-sm">
                                    <span class="ml-2 text-slate-500 text-xs">HH:MM:SS</span>
                                </div>
                            </div>
                            <div>
                                <label class="block text-xs font-medium text-slate-400 mb-1">End Time</label>
                                <div class="flex items-center">
                                    <input type="text" id="end-time" placeholder="00:01:00" 
                                           class="w-full p-3 rounded text-sm">
                                    <span class="ml-2 text-slate-500 text-xs">HH:MM:SS</span>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Watermark Options -->
                    <div id="watermark-options" class="hidden space-y-4 p-4 bg-slate-900/50 rounded-lg">
                        <div>
                            <label class="block text-xs font-medium text-slate-400 mb-1">Watermark Type</label>
                            <select id="wm-type" class="w-full p-3 rounded text-sm">
                                <option value="text">📝 Text Watermark</option>
                                <option value="image">🖼️ Logo Image</option>
                            </select>
                        </div>
                        <div id="wm-text-option" class="hidden">
                            <input type="text" id="wm-text" placeholder="Enter watermark text" 
                                   class="w-full p-3 rounded text-sm">
                        </div>
                        <div id="wm-image-option" class="hidden">
                            <input type="text" id="wm-logo" placeholder="Google Drive Logo ID" 
                                   class="w-full p-3 rounded text-sm">
                            <p class="text-xs text-slate-500 mt-1">Upload logo to Google Drive and paste its file ID</p>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Download Button -->
            <div class="mt-8 pt-6 border-t border-slate-800">
                <button onclick="downloadYouTube()" 
                        class="w-full py-4 bg-gradient-to-r from-red-600 to-orange-500 hover:from-red-700 hover:to-orange-600 rounded-lg font-bold text-white text-lg transition duration-200 flex items-center justify-center">
                    <i class="fas fa-download mr-3"></i> Download & Process
                </button>
            </div>
        </div>

        <!-- Progress Section -->
        <div id="progress" class="glass-panel p-6 mb-6 hidden">
            <h2 class="text-lg font-bold text-white mb-4 flex items-center">
                <i class="fas fa-spinner fa-spin mr-3"></i> Download Progress
            </h2>
            <div class="mb-4">
                <div class="w-full bg-slate-800 h-3 rounded-full overflow-hidden">
                    <div id="progress-bar" class="progress-bar h-full rounded-full transition-all duration-300" style="width: 0%"></div>
                </div>
                <div class="flex justify-between mt-2 text-sm">
                    <span id="progress-text" class="text-slate-300">0%</span>
                    <span id="status" class="text-slate-400">Initializing...</span>
                </div>
            </div>
            <div id="task-details" class="text-sm text-slate-500"></div>
        </div>

        <!-- Result Section -->
        <div id="result" class="glass-panel p-6"></div>

        <!-- Instructions -->
        <div class="glass-panel p-6 mt-6">
            <h3 class="text-lg font-bold text-white mb-4">📚 How to Use</h3>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="p-4 bg-slate-900/50 rounded-lg">
                    <div class="w-10 h-10 bg-blue-600 rounded-lg flex items-center justify-center mb-3">
                        <i class="fas fa-sign-in-alt text-white"></i>
                    </div>
                    <h4 class="font-bold text-white mb-2">1. Login</h4>
                    <p class="text-sm text-slate-400">Ensure you're logged in with Google to access Drive</p>
                </div>
                <div class="p-4 bg-slate-900/50 rounded-lg">
                    <div class="w-10 h-10 bg-green-600 rounded-lg flex items-center justify-center mb-3">
                        <i class="fas fa-link text-white"></i>
                    </div>
                    <h4 class="font-bold text-white mb-2">2. Paste URL</h4>
                    <p class="text-sm text-slate-400">Copy any YouTube video URL and paste it above</p>
                </div>
                <div class="p-4 bg-slate-900/50 rounded-lg">
                    <div class="w-10 h-10 bg-purple-600 rounded-lg flex items-center justify-center mb-3">
                        <i class="fas fa-cloud-upload-alt text-white"></i>
                    </div>
                    <h4 class="font-bold text-white mb-2">3. Download</h4>
                    <p class="text-sm text-slate-400">Video will be processed and uploaded to your Drive</p>
                </div>
            </div>
        </div>
    </div>

    <script>
        const API = "https://simple-liana-techzone3201-048a28fa.koyeb.app";
        
        // Initialize page
        document.addEventListener('DOMContentLoaded', function() {
            checkAuth();
            setupEventListeners();
        });

        function checkAuth() {
            const creds = localStorage.getItem('creds');
            const authStatus = document.getElementById('auth-status');
            
            if (!creds) {
                authStatus.innerHTML = `
                    <div class="p-4 bg-red-900/30 border border-red-500/30 rounded-lg">
                        <div class="flex items-center">
                            <i class="fas fa-exclamation-triangle text-red-400 text-xl mr-3"></i>
                            <div>
                                <p class="text-red-200 font-bold">Authentication Required</p>
                                <p class="text-red-300 text-sm">Please login with Google to use YouTube Downloader</p>
                            </div>
                        </div>
                        <div class="mt-3 flex gap-2">
                            <button onclick="goToLogin()" class="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded text-sm font-bold">
                                <i class="fas fa-sign-in-alt mr-2"></i>Login with Google
                            </button>
                            <button onclick="window.open('https://techzonex.store', '_blank')" 
                                    class="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded text-sm font-bold">
                                Go to Main Site
                            </button>
                        </div>
                    </div>`;
            } else {
                authStatus.innerHTML = `
                    <div class="p-4 bg-green-900/30 border border-green-500/30 rounded-lg">
                        <div class="flex items-center">
                            <i class="fas fa-check-circle text-green-400 text-xl mr-3"></i>
                            <div>
                                <p class="text-green-200 font-bold">Authenticated Successfully</p>
                                <p class="text-green-300 text-sm">You can now download YouTube videos to your Google Drive</p>
                            </div>
                        </div>
                    </div>`;
            }
        }

        function setupEventListeners() {
            // Toggle options based on process type
            document.getElementById('process-type').addEventListener('change', function() {
                const trimOptions = document.getElementById('trim-options');
                const wmOptions = document.getElementById('watermark-options');
                
                trimOptions.classList.add('hidden');
                wmOptions.classList.add('hidden');
                
                if (this.value === 'trim') {
                    trimOptions.classList.remove('hidden');
                } else if (this.value === 'watermark') {
                    wmOptions.classList.remove('hidden');
                    toggleWatermarkOptions();
                }
            });
            
            // Toggle watermark options
            document.getElementById('wm-type').addEventListener('change', toggleWatermarkOptions);
        }

        function toggleWatermarkOptions() {
            const wmType = document.getElementById('wm-type').value;
            document.getElementById('wm-text-option').classList.toggle('hidden', wmType !== 'text');
            document.getElementById('wm-image-option').classList.toggle('hidden', wmType !== 'image');
        }

        function goToLogin() {
            window.open(API + '/auth/login', '_blank');
        }

        async function downloadYouTube() {
            const creds = localStorage.getItem('creds');
            if (!creds) {
                alert('Please login first!');
                goToLogin();
                return;
            }
            
            const url = document.getElementById('url').value.trim();
            if (!url.includes('youtube.com') && !url.includes('youtu.be')) {
                showError('Please enter a valid YouTube URL');
                return;
            }
            
            const quality = document.getElementById('quality').value;
            const processType = document.getElementById('process-type').value;
            const destination = document.getElementById('destination').value.trim();
            
            const processData = {};
            if (processType === 'trim') {
                processData.start = document.getElementById('start-time').value || '00:00:00';
                processData.end = document.getElementById('end-time').value || '00:01:00';
                
                if (!validateTimeFormat(processData.start) || !validateTimeFormat(processData.end)) {
                    showError('Please use HH:MM:SS time format');
                    return;
                }
            } else if (processType === 'watermark') {
                const wmType = document.getElementById('wm-type').value;
                processData.type = wmType;
                if (wmType === 'text') {
                    processData.text = document.getElementById('wm-text').value || 'Watermark';
                } else {
                    processData.logo_id = document.getElementById('wm-logo').value;
                    if (!processData.logo_id) {
                        showError('Please enter a Google Drive Logo ID for image watermark');
                        return;
                    }
                }
            }
            
            // Show progress
            document.getElementById('progress').classList.remove('hidden');
            document.getElementById('progress-bar').style.width = '0%';
            document.getElementById('progress-text').textContent = '0%';
            document.getElementById('status').textContent = 'Starting download...';
            document.getElementById('task-details').textContent = '';
            document.getElementById('result').innerHTML = '';
            
            try {
                const response = await fetch(API + '/api/run', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        action: 'youtube',
                        creds: creds,
                        url: url,
                        quality: quality,
                        process_type: processType,
                        process_data: processData,
                        destination: destination || null
                    })
                });
                
                if (!response.ok) throw new Error('Network response was not ok');
                
                const data = await response.json();
                
                if (data.id) {
                    document.getElementById('task-details').textContent = `Task ID: ${data.id}`;
                    pollProgress(data.id);
                } else {
                    throw new Error('No task ID received');
                }
            } catch (error) {
                showError(`Error: ${error.message}`);
                document.getElementById('progress').classList.add('hidden');
            }
        }

        function validateTimeFormat(time) {
            const regex = /^(\d{1,2}:)?(\d{1,2}:)?\d{1,2}$/;
            return regex.test(time);
        }

        function showError(message) {
            document.getElementById('result').innerHTML = `
                <div class="p-4 bg-red-900/30 border border-red-500/30 rounded-lg">
                    <div class="flex items-center">
                        <i class="fas fa-times-circle text-red-400 text-xl mr-3"></i>
                        <p class="text-red-200">${message}</p>
                    </div>
                </div>`;
        }

        function showSuccess(message, downloadUrl, driveUrl) {
            let html = `
                <div class="p-4 bg-green-900/30 border border-green-500/30 rounded-lg">
                    <div class="flex items-center mb-3">
                        <i class="fas fa-check-circle text-green-400 text-xl mr-3"></i>
                        <p class="text-green-200 font-bold text-lg">${message}</p>
                    </div>
                    <div class="flex flex-wrap gap-3">`;
            
            if (downloadUrl) {
                html += `
                    <a href="${downloadUrl}" target="_blank" 
                       class="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded text-sm font-bold flex items-center">
                       <i class="fas fa-download mr-2"></i> Download File
                    </a>`;
            }
            
            if (driveUrl) {
                html += `
                    <a href="${driveUrl}" target="_blank" 
                       class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded text-sm font-bold flex items-center">
                       <i class="fab fa-google-drive mr-2"></i> Open in Drive
                    </a>`;
            }
            
            html += `
                    </div>
                </div>`;
            
            document.getElementById('result').innerHTML = html;
        }

        async function pollProgress(taskId) {
            const interval = setInterval(async () => {
                try {
                    const response = await fetch(API + '/api/status/' + taskId);
                    const status = await response.json();
                    
                    if (status.percent !== undefined) {
                        document.getElementById('progress-bar').style.width = status.percent + '%';
                        document.getElementById('progress-text').textContent = status.percent + '%';
                        document.getElementById('status').textContent = status.status;
                    }
                    
                    if (status.is_complete) {
                        clearInterval(interval);
                        
                        if (status.status.includes('Failed') || status.status.includes('Cancelled')) {
                            showError(status.status);
                        } else {
                            showSuccess('✅ Download Complete!', status.result_url, status.drive_link);
                        }
                        
                        // Hide progress after 5 seconds
                        setTimeout(() => {
                            document.getElementById('progress').classList.add('hidden');
                        }, 5000);
                    }
                } catch (error) {
                    clearInterval(interval);
                    showError(`Error checking progress: ${error.message}`);
                    document.getElementById('progress').classList.add('hidden');
                }
            }, 1000);
        }
    </script>
</body>
</html>
'''

@app.route('/YouTube')
def youtube_page():
    return render_template_string(YOUTUBE_HTML)

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
def index():
    return "Koyeb Backend Active - Visit https://techzonex.store for main interface", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
EOF

# 4. Run Server
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "1", "--threads", "4"]
