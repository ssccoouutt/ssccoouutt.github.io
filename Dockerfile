FROM python:3.9-slim

# 1. Install system dependencies
# Added 'build-essential' for compiling Python packages
# Added 'file' and 'libmagic1' which are often needed for file type detection
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    imagemagick \
    wget \
    git \
    build-essential \
    libmagic1 \
    file && \
    # 2. Fix ImageMagick Policy (Fail-safe: only runs if file exists)
    # This enables text rendering for MoviePy
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    # 3. Cleanup to reduce image size
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements first (better caching)
COPY requirements.txt .

# 4. Install Python dependencies
# Added --no-cache-dir to keep image small
# Added --upgrade pip to avoid wheel issues
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application
COPY . .

# Run the application
# Increased timeout to 600s because video processing takes time
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "600"]
