FROM python:3.11-slim

WORKDIR /app

# Install git for online update functionality
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

# Clone the repository to get full git history
RUN git clone --depth 1 https://github.com/sdacasda/TTS.git /tmp/repo && \
    cp -r /tmp/repo/ttl/backend/* /app/ && \
    cd /app && \
    git init && \
    git remote add origin https://github.com/sdacasda/TTS.git && \
    git fetch --depth 1 origin main && \
    git checkout -b main origin/main && \
    rm -rf /tmp/repo

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
