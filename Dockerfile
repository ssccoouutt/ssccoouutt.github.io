FROM python:3.9-slim

# Install system dependencies
# build-essential: for compiling numpy/pillow
# ffmpeg & imagemagick: for video processing
# wget: for downloading fonts
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    imagemagick \
    wget \
    build-essential \
    libmagic1 \
    file && \
    # Fix ImageMagick policy to allow text rendering
    if [ -f /etc/ImageMagick-6/policy.xml ]; then \
        sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY . .

# Increase timeout for video processing
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "600"]
