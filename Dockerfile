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
    # Fix ImageMagick policy
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

# Create folders
RUN mkdir -p /tmp drive /app/cookies

# 3. Create empty cookies file
RUN touch /app/cookies/cookies.txt && \
    echo "# Netscape HTTP Cookie File" > /app/cookies/cookies.txt

# ==========================================
# 4. BACKEND CODE (app.py) - FIXED VERSION
# ==========================================
RUN cat << 'EOF' > app.py
import os, json, uuid, time, io, sys, logging, traceback, threading, shutil
import subprocess, datetime, re, mimetypes
import numpy as np
from flask import Flask, request, jsonify, redirect, session, send_file, Response
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

# YouTube cookies file ID
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

# --- COOKIES HANDLER ---
def load_cookies_from_drive(service):
    """Download cookies from Google Drive using service object"""
    try:
        if not service:
            logger.warning("No Google Drive service provided, skipping cookie download")
            return False
            
        logger.info("Downloading cookies from Google Drive...")
        try:
            request = service.files().get_media(fileId=YOUTUBE_COOKIES_FILE_ID)
            cookies_content = io.BytesIO()
            downloader = MediaIoBaseDownload(cookies_content, request)
            done = False
            
            while not done:
                status, done = downloader.next_chunk()
            
            cookies_content = cookies_content.getvalue().decode('utf-8', errors='ignore')
            
            # Save to file
            with open(YOUTUBE_COOKIES_FILE, 'w', encoding='utf-8') as f:
                f.write(cookies_content)
            
            logger.info(f"Cookies downloaded: {len(cookies_content)} bytes")
            return True
            
        except Exception as drive_error:
            logger.error(f"Failed to download cookies from Drive: {drive_error}")
            # Check if cookies file already exists
            if os.path.exists(YOUTUBE_COOKIES_FILE) and os.path.getsize(YOUTUBE_COOKIES_FILE) > 100:
                logger.info("Using existing cookies file")
                return True
            return False
        
    except Exception as e:
        logger.error(f"Failed to load cookies: {e}")
        return False

# --- YOUTUBE UTILITIES ---
def get_video_info(url, service=None):
    """Get video information and available formats"""
    try:
        ydl_opts = {
            'quiet': True,
            'no_warnings': True,
            'extract_flat': False,
            'skip_download': True,
        }
        
        # Add cookies if available
        if service:
            load_cookies_from_drive(service)
        elif os.path.exists(YOUTUBE_COOKIES_FILE) and os.path.getsize(YOUTUBE_COOKIES_FILE) > 100:
            ydl_opts['cookiefile'] = YOUTUBE_COOKIES_FILE
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            
            # Extract available formats
            formats = []
            for f in info.get('formats', []):
                if not f.get('format_id'):
                    continue
                    
                format_info = {
                    'format_id': f.get('format_id', ''),
                    'ext': f.get('ext', ''),
                    'resolution': f.get('resolution', ''),
                    'height': f.get('height', 0),
                    'width': f.get('width', 0),
                    'filesize': f.get('filesize', 0),
                    'vcodec': f.get('vcodec', 'none'),
                    'acodec': f.get('acodec', 'none'),
                    'format_note': f.get('format_note', ''),
                    'fps': f.get('fps', 0),
                }
                
                # Determine type
                if f.get('vcodec', 'none') != 'none' and f.get('acodec', 'none') != 'none':
                    format_info['type'] = 'video+audio'
                elif f.get('vcodec', 'none') != 'none':
                    format_info['type'] = 'video'
                elif f.get('acodec', 'none') != 'none':
                    format_info['type'] = 'audio'
                else:
                    format_info['type'] = 'unknown'
                
                # Create display name
                if format_info['type'] == 'audio':
                    format_info['display_name'] = f"🎵 Audio ({format_info['ext'].upper()}) - {format_info['format_note'] or format_info['format_id']}"
                elif format_info['height']:
                    format_info['display_name'] = f"📹 {format_info['height']}p ({format_info['ext'].upper()}) - {format_info['format_note'] or format_info['format_id']}"
                else:
                    format_info['display_name'] = f"📁 {format_info['format_note'] or format_info['format_id']} ({format_info['ext'].upper()})"
                
                formats.append(format_info)
            
            # Sort formats by height (descending) then by type
            formats.sort(key=lambda x: (
                0 if x['type'] == 'video+audio' else 
                1 if x['type'] == 'video' else 
                2 if x['type'] == 'audio' else 3,
                -x.get('height', 0)
            ))
            
            # Get best formats
            video_formats = [f for f in formats if f['type'] in ['video+audio', 'video']]
            audio_formats = [f for f in formats if f['type'] == 'audio']
            
            best_video = max(video_formats, key=lambda x: x.get('height', 0)) if video_formats else None
            best_audio = max(audio_formats, key=lambda x: x.get('filesize', 0)) if audio_formats else None
            
            return {
                'success': True,
                'title': info.get('title', 'Unknown'),
                'duration': info.get('duration', 0),
                'thumbnail': info.get('thumbnail', ''),
                'uploader': info.get('uploader', ''),
                'view_count': info.get('view_count', 0),
                'like_count': info.get('like_count', 0),
                'formats': formats,
                'best_video': best_video,
                'best_audio': best_audio,
                'video_id': info.get('id', '')
            }
            
    except Exception as e:
        logger.error(f"Error getting video info: {e}")
        traceback.print_exc()
        return {'success': False, 'error': str(e)}

def download_youtube_video(url, format_id, download_dir=TEMP_DIR):
    """Download YouTube video with specific format"""
    try:
        ydl_opts = {
            'format': format_id,
            'outtmpl': os.path.join(download_dir, '%(title)s.%(ext)s'),
            'quiet': False,
            'no_warnings': True,
            'extract_flat': False,
            'merge_output_format': 'mp4',
            'postprocessors': [],
        }
        
        # Add cookies if available
        if os.path.exists(YOUTUBE_COOKIES_FILE) and os.path.getsize(YOUTUBE_COOKIES_FILE) > 100:
            ydl_opts['cookiefile'] = YOUTUBE_COOKIES_FILE
            logger.info("Using cookies file for download")
        
        # Check if format is audio only
        with yt_dlp.YoutubeDL({'quiet': True}) as ydl_temp:
            info = ydl_temp.extract_info(url, download=False)
            for f in info.get('formats', []):
                if f.get('format_id') == format_id:
                    if f.get('vcodec') == 'none' and f.get('acodec') != 'none':
                        # Audio only - convert to mp3
                        ydl_opts['postprocessors'].append({
                            'key': 'FFmpegExtractAudio',
                            'preferredcodec': 'mp3',
                            'preferredquality': '192',
                        })
                        logger.info(f"Audio format detected: {format_id}")
                    else:
                        # Video - ensure mp4 output
                        ydl_opts['postprocessors'].append({
                            'key': 'FFmpegVideoConvertor',
                            'preferedformat': 'mp4',
                        })
                        logger.info(f"Video format detected: {format_id}")
                    break
        
        logger.info(f"Downloading with format: {format_id}")
        
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            downloaded_file = ydl.prepare_filename(info)
            
            # Handle post-processing filename changes
            if ydl_opts['postprocessors'] and ydl_opts['postprocessors'][0].get('key') == 'FFmpegExtractAudio':
                # For audio downloads, the filename changes
                downloaded_file = downloaded_file.rsplit('.', 1)[0] + '.mp3'
            
            # Ensure correct extension
            if not os.path.exists(downloaded_file):
                # Try to find the actual file
                base_name = downloaded_file.rsplit('.', 1)[0]
                for ext in ['.mp4', '.mkv', '.webm', '.mp3', '.m4a', '.flv', '.avi']:
                    test_path = base_name + ext
                    if os.path.exists(test_path):
                        downloaded_file = test_path
                        logger.info(f"Found file: {test_path}")
                        break
            
            if not os.path.exists(downloaded_file):
                raise Exception(f"Downloaded file not found: {downloaded_file}")
            
            logger.info(f"Download successful: {downloaded_file}")
            return {
                'success': True,
                'file_path': downloaded_file,
                'title': info.get('title', 'Unknown'),
                'format_id': format_id,
                'duration': info.get('duration', 0)
            }
            
    except Exception as e:
        logger.error(f"YouTube download error: {e}")
        traceback.print_exc()
        return {'success': False, 'error': str(e)}

# --- PROGRESS TRACKER ---
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
        self.video_info = {}
        self.save()
    
    def update(self, status, pct=None):
        if TASK_FLAGS.get(self.task_id): 
            raise Exception("Cancelled")
        self.status = status
        if pct is not None: 
            self.percent = pct
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

# --- GOOGLE DRIVE HELPERS ---
def get_service(creds):
    try:
        creds_dict = json.loads(creds)
        c = Credentials.from_authorized_user_info(creds_dict, SCOPES)
        if c.expired and c.refresh_token: 
            c.refresh(Request())
        return build("drive", "v3", credentials=c)
    except Exception as e:
        logger.error(f"Error creating Drive service: {e}")
        raise

def extract_id(url):
    if not url: return None
    url = str(url).strip()
    if 'file/d/' in url: return url.split('file/d/')[1].split('/')[0]
    if 'folders/' in url: return url.split('folders/')[1].split('?')[0]
    if 'id=' in url: return url.split('id=')[1].split('&')[0]
    return url

def upload_file(service, path, name, parent=None):
    try:
        meta = {'name': name}
        if parent: meta['parents'] = [parent]
        
        # Detect mime type
        mime_type = mimetypes.guess_type(path)[0] or 'application/octet-stream'
        media = MediaFileUpload(path, mimetype=mime_type, resumable=True)
        f = service.files().create(body=meta, media_body=media, fields='id, webViewLink').execute()
        logger.info(f"File uploaded to Drive: {name} (ID: {f.get('id')})")
        return f
    except Exception as e:
        logger.error(f"Upload error: {e}")
        raise

# --- API ENDPOINTS ---
@app.route('/api/youtube/info', methods=['POST'])
def youtube_info():
    """Get YouTube video information and available formats"""
    try:
        data = request.json
        url = data.get('url')
        creds = data.get('creds')
        
        if not url:
            return jsonify({'success': False, 'error': 'Missing URL'})
        
        service = None
        if creds:
            try:
                service = get_service(creds)
            except Exception as e:
                logger.warning(f"Could not create Drive service, continuing without cookies: {e}")
        
        result = get_video_info(url, service)
        
        if result['success']:
            # Store video info for later use
            video_id = result.get('video_id', '')
            if video_id:
                cache_key = f"youtube_info_{video_id}"
                TASKS[cache_key] = result
            
            # Simplify formats for frontend
            simplified_formats = []
            for fmt in result['formats']:
                if fmt['type'] in ['video+audio', 'video']:
                    simplified_formats.append({
                        'id': fmt['format_id'],
                        'name': fmt['display_name'],
                        'type': 'video'
                    })
                elif fmt['type'] == 'audio':
                    simplified_formats.append({
                        'id': fmt['format_id'],
                        'name': fmt['display_name'],
                        'type': 'audio'
                    })
            
            best_video_id = result.get('best_video', {}).get('format_id', '')
            best_audio_id = result.get('best_audio', {}).get('format_id', '')
            
            return jsonify({
                'success': True,
                'title': result['title'],
                'duration': result['duration'],
                'thumbnail': result['thumbnail'],
                'uploader': result['uploader'],
                'formats': simplified_formats,
                'best_video': best_video_id,
                'best_audio': best_audio_id,
                'video_id': video_id
            })
        else:
            return jsonify(result)
            
    except Exception as e:
        logger.error(f"Error in youtube_info: {e}")
        traceback.print_exc()
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/youtube/download', methods=['POST'])
def youtube_download():
    """Download YouTube video with selected format"""
    data = request.json
    url = data.get('url')
    format_id = data.get('format_id')
    destination = data.get('destination')
    creds = data.get('creds')
    
    if not url or not format_id:
        return jsonify({'success': False, 'error': 'Missing URL or format ID'})
    
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        tracker = ProgressTracker(task_id, "YouTube Download")
        try:
            tracker.update("Initializing...", 5)
            
            service = None
            if creds:
                try:
                    service = get_service(creds)
                    tracker.update("Connected to Google Drive", 10)
                except Exception as e:
                    logger.warning(f"Drive service error: {e}")
                    tracker.update("Google Drive not available, downloading locally only", 10)
            
            # Get video info first
            tracker.update("Fetching video information...", 20)
            video_info = get_video_info(url, service)
            if not video_info['success']:
                raise Exception(f"Failed to get video info: {video_info.get('error', 'Unknown error')}")
            
            tracker.video_info = {
                'title': video_info.get('title', ''),
                'duration': video_info.get('duration', 0),
                'uploader': video_info.get('uploader', '')
            }
            
            # Download the video
            tracker.update(f"Downloading {format_id}...", 40)
            result = download_youtube_video(url, format_id, TEMP_DIR)
            
            if not result['success']:
                raise Exception(f"Download failed: {result.get('error', 'Unknown error')}")
            
            downloaded_path = result['file_path']
            
            if service and creds:
                # Upload to Google Drive if service is available
                tracker.update("Uploading to Google Drive...", 70)
                parent_id = extract_id(destination) if destination else None
                
                # Get original title for filename
                original_title = video_info.get('title', 'YouTube_Video')
                safe_title = re.sub(r'[^\w\s-]', '', original_title).strip()[:100]
                
                # Determine file extension
                ext = os.path.splitext(downloaded_path)[1] or '.mp4'
                upload_name = f"{safe_title}{ext}"
                
                try:
                    uploaded = upload_file(service, downloaded_path, upload_name, parent_id)
                    drive_link = uploaded.get('webViewLink')
                    tracker.update("Upload complete", 90)
                except Exception as upload_error:
                    logger.error(f"Upload failed: {upload_error}")
                    drive_link = None
                    tracker.update("Google Drive upload failed, providing local download", 90)
            else:
                drive_link = None
                tracker.update("Skipping Google Drive upload", 90)
            
            # Create local download link
            local_filename = os.path.basename(downloaded_path)
            local_path = os.path.join(TEMP_DIR, local_filename)
            
            # Ensure file is in TEMP_DIR
            if downloaded_path != local_path and os.path.exists(downloaded_path):
                shutil.move(downloaded_path, local_path)
            
            tracker.complete(
                url=f"{SERVER_DOMAIN}/api/dl/{local_filename}",
                drive_link=drive_link
            )
            
        except Exception as e:
            tracker.fail(str(e))
            traceback.print_exc()
    
    threading.Thread(target=worker).start()
    return jsonify({'success': True, 'task_id': task_id})

@app.route('/api/youtube/stream/<video_id>')
def youtube_stream(video_id):
    """Stream YouTube video directly"""
    try:
        # This is a simplified version - in production you'd need to handle
        # actual streaming from YouTube or your downloaded file
        return jsonify({
            'success': True,
            'message': 'Streaming endpoint',
            'video_id': video_id
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/run', methods=['POST'])
def run_task():
    """Handle other tasks (legacy support)"""
    data = request.json
    action = data.get('action')
    task_id = str(uuid.uuid4())[:8]
    
    def worker():
        tracker = ProgressTracker(task_id, action)
        try:
            if action == "youtube":
                # This is handled by the new endpoint above
                tracker.complete()
            else:
                tracker.update(f"Processing {action}...", 50)
                time.sleep(2)  # Simulate work
                tracker.complete()
                
        except Exception as e:
            tracker.fail(str(e))
    
    threading.Thread(target=worker).start()
    return jsonify({'id': task_id})

@app.route('/api/status/<task_id>')
def get_status(task_id):
    task = TASKS.get(task_id)
    if task:
        return jsonify(task)
    return jsonify({'status': 'Not found', 'is_complete': True})

@app.route('/api/cancel/<task_id>', methods=['POST'])
def cancel_task(task_id):
    TASK_FLAGS[task_id] = True
    return jsonify({'status': 'cancelled'})

@app.route('/api/dl/<filename>')
def download_file(filename):
    """Download file from temp directory"""
    filepath = os.path.join(TEMP_DIR, filename)
    if os.path.exists(filepath):
        return send_file(filepath, as_attachment=True)
    return jsonify({'error': 'File not found'}), 404

@app.route('/api/preview/<filename>')
def preview_file(filename):
    """Preview video/audio file"""
    filepath = os.path.join(TEMP_DIR, filename)
    if os.path.exists(filepath):
        mime_type = mimetypes.guess_type(filepath)[0] or 'application/octet-stream'
        
        if mime_type.startswith('video/') or mime_type.startswith('audio/'):
            # Return file for HTML5 player
            return send_file(filepath, mimetype=mime_type)
        else:
            return send_file(filepath, as_attachment=True)
    
    return jsonify({'error': 'File not found'}), 404

# --- AUTH ENDPOINTS ---
@app.route('/auth/login')
def login():
    try:
        flow = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES)
        flow.redirect_uri = f"{SERVER_DOMAIN}/callback"
        auth_url, state = flow.authorization_url(access_type='offline', prompt='consent')
        session['state'] = state
        return redirect(auth_url)
    except Exception as e:
        logger.error(f"Login error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/callback')
def callback():
    try:
        flow = Flow.from_client_config(RAW_CREDENTIALS, scopes=SCOPES, state=session.get('state'))
        flow.redirect_uri = f"{SERVER_DOMAIN}/callback"
        flow.fetch_token(authorization_response=request.url)
        return redirect(f"{FRONTEND_URL}/#auth_data={json.dumps(flow.credentials.to_json())}")
    except Exception as e:
        logger.error(f"Callback error: {e}")
        return f"Authentication error: {e}", 500

@app.route('/')
def index():
    return jsonify({
        'status': 'TechZoneX Backend API - YouTube Downloader',
        'version': '2.0',
        'endpoints': [
            '/api/youtube/info - Get YouTube video info',
            '/api/youtube/download - Download YouTube video',
            '/auth/login - Google Drive authentication'
        ]
    })

@app.route('/health')
def health_check():
    return jsonify({'status': 'healthy', 'timestamp': datetime.datetime.now().isoformat()})

if __name__ == '__main__':
    # Create cookies directory if it doesn't exist
    if not os.path.exists(COOKIES_DIR):
        os.makedirs(COOKIES_DIR)
    
    # Initialize cookies file if it doesn't exist
    if not os.path.exists(YOUTUBE_COOKIES_FILE):
        with open(YOUTUBE_COOKIES_FILE, 'w') as f:
            f.write("# Netscape HTTP Cookie File\n")
    
    logger.info("TechZoneX YouTube Downloader starting...")
    app.run(host='0.0.0.0', port=8000, debug=False)
EOF

# 5. Run Server
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "1200", "--workers", "2", "--threads", "4", "--access-logfile", "-"]
