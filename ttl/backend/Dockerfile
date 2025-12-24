FROM python:3.11-slim

# Install git for online update functionality
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

# Clone the full repository
RUN git clone https://github.com/sdacasda/TTS.git /repo

# Set working directory to backend
WORKDIR /repo/ttl/backend

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
