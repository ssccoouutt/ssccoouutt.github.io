FROM python:3.9-slim

# Install system dependencies: FFmpeg, ImageMagick (for MoviePy), wget, fonts
RUN apt-get update && \
    apt-get install -y ffmpeg imagemagick wget git && \
    # Fix ImageMagick policy for text
    sed -i 's/none/read,write/g' /etc/ImageMagick-6/policy.xml && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application
COPY . .

# Run the application
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "600"]
