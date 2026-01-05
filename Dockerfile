FROM python:3.9-slim

# Install system dependencies including FFmpeg
RUN apt-get update && \
    apt-get install -y ffmpeg git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application
COPY . .

# Run the application (using gunicorn for production stability)
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000", "--timeout", "120"]
