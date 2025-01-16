#!/bin/bash

# Check if running as root and get the actual user
if [ "$EUID" -eq 0 ]; then
    ACTUAL_USER=$SUDO_USER
    USER_HOME=$(getent passwd $ACTUAL_USER | cut -d: -f6)
else
    ACTUAL_USER=$USER
    USER_HOME=$HOME
fi

# Create directory structure
SETUP_DIR="$USER_HOME/llm-setup"
echo "Creating directory structure in $SETUP_DIR"
mkdir -p "$SETUP_DIR"/{models,logs,scripts}

# Ensure correct ownership
if [ "$EUID" -eq 0 ]; then
    chown -R $ACTUAL_USER:$ACTUAL_USER "$SETUP_DIR"
fi

# Function to get memory information in MB
get_memory_info() {
    total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    available_mem=$(free -m | awk '/^Mem:/ {print $7}')
    swap_mem=$(free -m | awk '/^Swap:/ {print $2}')
    docker_limit=$((available_mem * 75 / 100))
    docker_reserve=$((available_mem * 50 / 100))
    echo "$total_mem $available_mem $swap_mem $docker_limit $docker_reserve"
}

# Get memory values
read total_mem available_mem swap_mem docker_limit docker_reserve <<< $(get_memory_info)

# Log memory information
echo "System Memory Information:"
echo "Total Memory: ${total_mem}MB"
echo "Available Memory: ${available_mem}MB"
echo "Swap Memory: ${swap_mem}MB"
echo "Docker Memory Limit: ${docker_limit}MB"
echo "Docker Memory Reservation: ${docker_reserve}MB"

# Install required packages
echo "Installing required packages..."
if [ "$EUID" -eq 0 ]; then
    apt-get update
    apt-get install -y python3-pip python3-venv docker.io docker-compose wget
else
    sudo apt-get update
    sudo apt-get install -y python3-pip python3-venv docker.io docker-compose wget
fi

# Download the Qwen model
echo "Downloading Qwen 2.5 3B GGUF model..."
cd "$SETUP_DIR/models"
if [ ! -f qwen2.5-3b-instruct-q8_0.gguf ]; then
    wget https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q8_0.gguf
fi

# Create configuration files
echo "Creating configuration files..."

# Memory config
cat > "$SETUP_DIR/memory_config.env" << EOL
TOTAL_MEMORY=${total_mem}
AVAILABLE_MEMORY=${available_mem}
SWAP_MEMORY=${swap_mem}
DOCKER_MEMORY_LIMIT=${docker_limit}m
DOCKER_MEMORY_RESERVE=${docker_reserve}m
N_THREADS=$(nproc)
N_BATCH=$((available_mem / 16))
N_CTX=2048
EOL

# Docker compose file
cat > "$SETUP_DIR/docker-compose.yml" << EOL
version: '3.8'

services:
  llm-api:
    build: .
    ports:
      - "8082:8082"
    volumes:
      - ./models:/app/models
      - ./logs:/app/logs
    env_file:
      - memory_config.env
    environment:
      - MODEL_PATH=/app/models/qwen2.5-3b-instruct-q8_0.gguf
      - LOG_PATH=/app/logs
    deploy:
      resources:
        limits:
          memory: \${DOCKER_MEMORY_LIMIT}
        reservations:
          memory: \${DOCKER_MEMORY_RESERVE}

  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml

  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
    depends_on:
      - prometheus
EOL

# Main Python file
cat > "$SETUP_DIR/main.py" << 'EOL'
import logging
import os
from fastapi import FastAPI, HTTPException, Request, Depends
from pydantic import BaseModel
from llama_cpp import Llama
from prometheus_client import Counter, Histogram, Gauge
import time
from datetime import datetime, timedelta
import jwt

# JWT Config
SECRET_KEY = "supersecretkey"
ALGORITHM = "HS256"
TOKEN_EXPIRATION_MINUTES = 30
TOKEN_FILE = "oauth_tokens.txt"

def save_token(token):
    with open(TOKEN_FILE, "a") as file:
        file.write(token + "\n")

def verify_token(token):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token has expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid token")

def create_token():
    expiration = datetime.utcnow() + timedelta(minutes=TOKEN_EXPIRATION_MINUTES)
    payload = {"exp": expiration, "iat": datetime.utcnow(), "sub": "user"}
    token = jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)
    save_token(token)
    return token

# Get environment variables
n_threads = int(os.getenv('N_THREADS', '4'))
n_batch = int(os.getenv('N_BATCH', '512'))
n_ctx = int(os.getenv('N_CTX', '2048'))

# Configure logging
logging.basicConfig(
    filename='logs/llm_api.log',
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

logging.info(f"System Configuration: threads={n_threads}, batch={n_batch}, ctx={n_ctx}")

# Metrics
INFERENCE_TIME = Histogram('inference_time_seconds', 'Time spent processing inference')
INFERENCE_REQUESTS = Counter('inference_requests_total', 'Total number of inference requests')
MEMORY_USAGE = Gauge('memory_usage_bytes', 'Current memory usage')

app = FastAPI()

MODEL_PATH = os.getenv('MODEL_PATH', 'models/qwen2.5-3b-instruct-q8_0.gguf')
try:
    model = Llama(
        model_path=MODEL_PATH,
        n_ctx=n_ctx,
        n_threads=n_threads,
        n_batch=n_batch
    )
    logging.info(f"Model loaded successfully from {MODEL_PATH}")
except Exception as e:
    logging.error(f"Failed to load model: {str(e)}")
    raise

class Query(BaseModel):
    text: str
    max_tokens: int = 512
    temperature: float = 0.7

@app.post("/generate")
async def generate_text(query: Query, token: str = Depends(verify_token)):
    try:
        INFERENCE_REQUESTS.inc()
        start_time = time.time()
        
        MEMORY_USAGE.set(os.popen('free -b').readlines()[1].split()[2])
        
        response = model(
            query.text,
            max_tokens=query.max_tokens,
            temperature=query.temperature,
            stop=["</s>", "Human:", "Assistant:"],
            echo=False
        )
        
        INFERENCE_TIME.observe(time.time() - start_time)
        
        return {
            "response": response['choices'][0]['text'],
            "usage": {
                "prompt_tokens": response['usage']['prompt_tokens'],
                "completion_tokens": response['usage']['completion_tokens'],
                "total_tokens": response['usage']['total_tokens']
            }
        }
    except Exception as e:
        logging.error(f"Error generating response: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/system/memory")
async def get_memory_info():
    mem_info = os.popen('free -h').readlines()[1].split()
    return {
        "total": mem_info[1],
        "used": mem_info[2],
        "available": mem_info[6],
        "model_settings": {
            "n_threads": n_threads,
            "n_batch": n_batch,
            "n_ctx": n_ctx
        }
    }

@app.post("/token")
async def generate_token():
    token = create_token()
    return {"token": token}
EOL

# Create Dockerfile
cat > "$SETUP_DIR/Dockerfile" << 'EOL'
FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8082"]
EOL

# Create requirements.txt
cat > "$SETUP_DIR/requirements.txt" << 'EOL'
fastapi
uvicorn
pydantic
python-dotenv
prometheus_client
llama-cpp-python
pyjwt
EOL

# Ensure correct permissions
if [ "$EUID" -eq 0 ]; then
    chown -R $ACTUAL_USER:$ACTUAL_USER "$SETUP_DIR"
fi

echo "Setup complete! System configured in $SETUP_DIR"
echo "To start the service:"
echo "1. cd $SETUP_DIR"
echo "2. docker-compose up --build"
echo ""
echo "Check memory status:"
echo "curl http://localhost:8082/system/memory"
