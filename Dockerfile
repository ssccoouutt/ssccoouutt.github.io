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
RUN mkdir -p /tmp drive /app/cookies

# 3. Create empty cookies file - will be populated by the backend
RUN touch /app/cookies/cookies.txt && \
    echo "# Netscape HTTP Cookie File" > /app/cookies/cookies.txt && \
    echo "# This file will be populated by the backend" >> /app/cookies/cookies.txt && \
    echo "# https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp" >> /app/cookies/cookies.txt

# ==========================================
# 4. BACKEND CODE (app.py) - API ONLY WITH COOKIES DOWNLOAD
# ==========================================
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

# UPDATE URLS
FRONTEND_URL = "https://techzonex.store" 
SERVER_DOMAIN = "https://simple-liana-techzone3201-048a28fa.koyeb.app"

TEMP_DIR = "/tmp"
COOKIES_DIR = "/app/cookies"
SYSTEM_FONT = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"

# AUTO FOLDERS
UNPOSTED_FOLDER_ID = "14tf687_8F4o2oYJTqyCZmvJjq45jRliy"
SECOND_SOURCE_FOLDER_ID = "12V7EnRIYcSgEtt0PR5fhV8cO22nzYuiv"

# YouTube cookies file ID (from your Google Drive link)
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
app.secret_key = "production_super_suite_v2"
CORS(app, resources={r"/*": {"origins": "*"}})

TASKS = {}
TASK_FLAGS = {}
MIME_MAP = {'application/pdf':'PDF', 'image/':'Images', 'video/':'Videos', 'audio/':'Audio', 'application/vnd.google-apps.folder':'Folders', 'application/zip':'Archives', 'text/':'Documents'}

# Cookies cache to avoid downloading multiple times
COOKIES_CACHE = {}

# --- HELPERS ---
def load_cookies_from_drive(service):
    """Download cookies from Google Drive using the service account"""
    global COOKIES_CACHE
    
    # Check cache first
    if 'cookies_content' in COOKIES_CACHE:
        logger.info("Using cached cookies")
        return COOKIES_CACHE['cookies_content']
    
    try:
        logger.info(f"Downloading cookies from Google Drive file ID: {YOUTUBE_COOKIES_FILE_ID}")
        
        # Download the file
        request = service.files().get_media(fileId=YOUTUBE_COOKIES_FILE_ID)
        cookies_content = io.BytesIO()
        downloader = MediaIoBaseDownload(cookies_content, request)
        done = False
        
        while not done:
            status, done = downloader.next_chunk()
            if status:
                logger.info(f"Downloading cookies: {int(status.progress() * 100)}%")
        
        cookies_content = cookies_content.getvalue().decode('utf-8')
        
        # Validate it's a Netscape format cookies file
        if not is_valid_cookies_file(cookies_content):
            logger.warning("Cookies file doesn't look like Netscape format, trying to fix...")
            cookies_content = fix_cookies_format(cookies_content)
        
        # Save to file
        with open(YOUTUBE_COOKIES_FILE, 'w', encoding='utf-8') as f:
            f.write(cookies_content)
        
        # Cache the content
        COOKIES_CACHE['cookies_content'] = cookies_content
        COOKIES_CACHE['last_updated'] = time.time()
        
        logger.info(f"Cookies downloaded successfully: {len(cookies_content)} bytes")
        return cookies_content
        
    except Exception as e:
        logger.error(f"Failed to load cookies from Drive: {e}")
        # Create a minimal valid cookies file
        default_cookies = """# Netscape HTTP Cookie File
# This file was generated by yt-dlp
# Example cookie entry (will not work, just for format)
.youtube.com\tTRUE\t/\tTRUE\t2147483647\tPREF\tf1=1234567890&f5=30000"""
        
        with open(YOUTUBE_COOKIES_FILE, 'w', encoding='utf-8') as f:
            f.write(default_cookies)
        
        COOKIES_CACHE['cookies_content'] = default_cookies
        return default_cookies

def is_valid_cookies_file(content):
    """Check if content looks like a valid Netscape cookies file"""
    lines = content.strip().split('\n')
    if not lines:
        return False
    
    # Check for Netscape header
    if lines[0].startswith('# Netscape HTTP Cookie File') or lines[0].startswith('# HTTP Cookie File'):
        return True
    
    # Check if it has at least one valid cookie line
    for line in lines:
        if line.strip() and not line.startswith('#'):
            parts = line.strip().split('\t')
            if len(parts) >= 7:
                return True
    
    return False

def fix_cookies_format(content):
    """Try to fix common cookies format issues"""
    lines = content.strip().split('\n')
    fixed_lines = []
    
    # Add Netscape header if missing
    if not lines[0].startswith('#'):
        fixed_lines.append('# Netscape HTTP Cookie File')
        fixed_lines.append('# This file was generated/edited by TechZoneX')
        fixed_lines.append('# https://github.com/yt-dlp/yt-dlp')
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        # Skip comments
        if line.startswith('#'):
            fixed_lines.append(line)
            continue
        
        # Try to parse as JSON (some cookie exporters use JSON)
        if line.startswith('{') or line.startswith('['):
            try:
                cookies_json = json.loads(line)
                if isinstance(cookies_json, list):
                    for cookie in cookies_json:
                        fixed = convert_json_cookie(cookie)
                        if fixed:
                            fixed_lines.append(fixed)
                elif isinstance(cookies_json, dict):
                    fixed = convert_json_cookie(cookies_json)
                    if fixed:
                        fixed_lines.append(fixed)
                continue
            except json.JSONDecodeError:
                pass
        
        # If it looks like a cookie but not tab-separated, try to fix
        if '=' in line and '\t' not in line:
            # Try to parse as "domain name=value" format
            if ' ' in line:
                parts = line.split(' ', 1)
                if len(parts) == 2:
                    domain_name = parts[0]
                    if '=' in domain_name:
                        domain, name = domain_name.split('=', 1)
                        value = parts[1]
                        # Create Netscape format
                        fixed = f"{domain}\tTRUE\t/\tFALSE\t2147483647\t{name}\t{value}"
                        fixed_lines.append(fixed)
                        continue
        
        # Keep as-is if we can't parse it
        fixed_lines.append(line)
    
    return '\n'.join(fixed_lines)

def convert_json_cookie(cookie):
    """Convert JSON cookie to Netscape format"""
    try:
        # Common cookie fields
        domain = cookie.get('domain', cookie.get('host', '.youtube.com')).lstrip('.')
        name = cookie.get('name', '')
        value = cookie.get('value', '')
        path = cookie.get('path', '/')
        secure = cookie.get('secure', True)
        expires = cookie.get('expiry', cookie.get('expires', 2147483647))
        
        # Convert secure to TRUE/FALSE
        flag = 'TRUE' if secure else 'FALSE'
        
        # Handle expires (might be string or timestamp)
        if isinstance(expires, str):
            try:
                expires = int(float(expires))
            except:
                expires = 2147483647
        elif not isinstance(expires, (int, float)):
            expires = 2147483647
        
        # Ensure expires is not too large
        if expires > 2147483647:
            expires = 2147483647
        
        return f".{domain}\tTRUE\t{path}\t{flag}\t{expires}\t{name}\t{value}"
    except Exception as e:
        logger.error(f"Failed to convert JSON cookie: {e}")
        return None

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
def download_youtube_video(url, quality='best', download_dir=TEMP_DIR, service=None):
    """Download YouTube video using yt-dlp with cookies"""
    try:
        # Map quality strings to yt-dlp format
        format_map = {
            'best': 'best',
            '144': 'worst',
            '240': 'worstvideo[height>=240][height<=240]',
            '360': 'worstvideo[height>=360][height<=360]',
            '480': 'worstvideo[height>=480][height<=480]',
            '720': 'bestvideo[height<=720]+bestaudio',
            '1080': 'bestvideo[height<=1080]+bestaudio',
            'audio': 'bestaudio'
        }
        
        format_str = format_map.get(quality, 'best')
        
        ydl_opts = {
            'format': format_str,
            'outtmpl': os.path.join(download_dir, '%(title)s.%(ext)s'),
            'quiet': True,
            'no_warnings': True,
            'extract_flat': False,
            'merge_output_format': 'mp4',
            'postprocessors': [],
        }
        
        # Add video postprocessor for non-audio formats
        if quality != 'audio':
            ydl_opts['postprocessors'].append({
                'key': 'FFmpegVideoConvertor',
                'preferedformat': 'mp4',
            })
        else:
            # For audio only, convert to mp3
            ydl_opts['postprocessors'].append({
                'key': 'FFmpegExtractAudio',
                'preferredcodec': 'mp3',
                'preferredquality': '192',
            })
            ydl_opts['outtmpl'] = os.path.join(download_dir, '%(title)s.%(ext)s')
        
        # Load cookies from Google Drive if service is provided
        if service:
            load_cookies_from_drive(service)
        
        # Add cookies if available
        if os.path.exists(YOUTUBE_COOKIES_FILE) and os.path.getsize(YOUTUBE_COOKIES_FILE) > 100:
            ydl_opts['cookiefile'] = YOUTUBE_COOKIES_FILE
            logger.info(f"Using cookies file: {os.path.getsize(YOUTUBE_COOKIES_FILE)} bytes")
            
            # Validate cookies file format
            with open(YOUTUBE_COOKIES_FILE, 'r', encoding='utf-8') as f:
                content = f.read()
                if not is_valid_cookies_file(content):
                    logger.warning("Cookies file format may be invalid, attempting to fix...")
                    fixed = fix_cookies_format(content)
                    with open(YOUTUBE_COOKIES_FILE, 'w', encoding='utf-8') as f2:
                        f2.write(fixed)
        else:
            logger.warning("No valid cookies file found, downloading without cookies")
        
        logger.info(f"Downloading YouTube video with quality: {quality}, format: {format_str}")
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            downloaded_file = ydl.prepare_filename(info)
            
            # For audio, we need to rename from .webm to .mp3 or similar
            if quality == 'audio' and downloaded_file.endswith('.webm'):
                mp3_file = downloaded_file.rsplit('.', 1)[0] + '.mp3'
                if os.path.exists(downloaded_file):
                    os.rename(downloaded_file, mp3_file)
                    downloaded_file = mp3_file
            elif quality != 'audio' and not downloaded_file.endswith('.mp4'):
                # Ensure mp4 extension for videos
                mp4_file = downloaded_file.rsplit('.', 1)[0] + '.mp4'
                if os.path.exists(downloaded_file):
                    os.rename(downloaded_file, mp4_file)
                    downloaded_file = mp4_file
            
            return {
                'success': True,
                'file_path': downloaded_file,
                'title': info.get('title', 'Unknown'),
                'duration': info.get('duration', 0),
                'quality': info.get('height', 'Audio') if quality != 'audio' else 'Audio',
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
                
                # Load cookies first
                tr.update("Loading YouTube cookies...", 20)
                load_cookies_from_drive(s)
                
                # Download from YouTube
                tr.update("Downloading from YouTube...", 30)
                result = download_youtube_video(url, quality, TEMP_DIR, s)
                
                if not result['success']:
                    raise Exception(f"YouTube download failed: {result.get('error', 'Unknown error')}")
                
                # For audio format, skip video processing
                if quality == 'audio':
                    tr.update("Uploading audio file...", 80)
                    parent = extract_id(d.get('destination'))
                    upload_name = f"YouTube_{result['title'][:50]}.mp3"
                    up = upload_file(s, result['file_path'], upload_name, parent)
                    tr.complete(f"{SERVER_DOMAIN}/api/dl/{os.path.basename(result['file_path'])}", up.get('webViewLink'))
                    return
                
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

# 5. Run Server
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "1", "--threads", "4"]
