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
SETUP_DIR="/app/llm-setup"
echo "Creating directory structure in $SETUP_DIR"
mkdir -p "$SETUP_DIR/models" "$SETUP_DIR/logs"

# Ensure correct ownership
if [ "$EUID" -eq 0 ]; then
    chown -R $ACTUAL_USER:$ACTUAL_USER "$SETUP_DIR"
fi

# Install required packages
echo "Installing required packages..."
apt-get update
apt-get install -y python3-pip python3-venv wget lsof logrotate || { echo "Package installation failed"; exit 1; }

# Detect system specs for optimization
GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)  # Total VRAM in MB
CPU_THREADS=$(lscpu | awk '/^CPU\(s\):/ {print $2}')  # Total CPU threads
N_THREADS=$((CPU_THREADS / 2))  # Use half of CPU threads for preprocessing
N_BATCH=$((GPU_VRAM / 12))      # Approximation: Allocate ~12MB per batch unit
N_CTX=1024                      # Default context size
if [[ $N_THREADS -lt 1 ]]; then N_THREADS=1; fi
if [[ $N_BATCH -lt 512 ]]; then N_BATCH=512; fi

# Create .env file
ENV_FILE="$SETUP_DIR/.env"
echo "Creating .env file with calculated settings..."
cat > "$ENV_FILE" <<EOL
N_THREADS=$N_THREADS
N_BATCH=$N_BATCH
N_CTX=$N_CTX
TOKEN_EXPIRATION_ENABLED=false  # Default to indefinite token life
TOKEN_EXPIRATION_MINUTES=30     # Time-based expiration duration, only used if enabled
EOL

echo ".env file created with the following settings:"
cat "$ENV_FILE"

# Download the Qwen model
echo "Downloading Qwen 2.5 3B GGUF model..."
cd "$SETUP_DIR/models"
if [ ! -f qwen2.5-3b-instruct-q8_0.gguf ]; then
    wget -O qwen2.5-3b-instruct-q8_0.gguf https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q8_0.gguf || { echo "Model download failed"; exit 1; }
else
    echo "Model file already exists. Skipping download."
fi

# Remove existing virtual environment
echo "Cleaning up existing virtual environment..."
if [ -d "$SETUP_DIR/venv" ]; then
    rm -rf "$SETUP_DIR/venv"
fi

# Create Python virtual environment
echo "Creating Python virtual environment..."
python3 -m venv "$SETUP_DIR/venv" || { echo "Failed to create virtual environment"; exit 1; }
source "$SETUP_DIR/venv/bin/activate"

# Install Python dependencies
pip install --upgrade pip
pip install fastapi uvicorn pydantic llama-cpp-python pyjwt python-dotenv cProfile || { echo "Failed to install dependencies"; exit 1; }

# Generate a default token and save it to oauth_tokens.txt
generate_default_token() {
    echo "Generating default OAuth token..."
    local default_token=$(python3 -c "
import jwt
from datetime import datetime
SECRET_KEY = 'SmartTasks'
ALGORITHM = 'HS256'
payload = {'iat': datetime.utcnow(), 'sub': 'default_user'}
token = jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)
print(token)")
    if [ -z "$default_token" ]; then
        echo "Failed to generate token"
        exit 1
    fi
    echo "$default_token" > "$SETUP_DIR/oauth_tokens.txt"
    echo "Default OAuth token generated and saved to $SETUP_DIR/oauth_tokens.txt"
}
generate_default_token

# Create main Python script
cat > "$SETUP_DIR/main.py" << 'EOL'
import logging
import os
from fastapi import FastAPI, HTTPException, Depends, Header
from llama_cpp import Llama
from dotenv import load_dotenv
import jwt
from datetime import datetime, timedelta
from typing import List, Optional
from pydantic import BaseModel
import cProfile

# Load environment variables
load_dotenv("/app/llm-setup/.env")

# Settings
N_THREADS = int(os.getenv("N_THREADS", 4))
N_BATCH = int(os.getenv("N_BATCH", 512))
N_CTX = int(os.getenv("N_CTX", 1024))
SECRET_KEY = "SmartTasks"
ALGORITHM = "HS256"
TOKEN_FILE = "/app/llm-setup/oauth_tokens.txt"
TOKEN_EXPIRATION_ENABLED = os.getenv("TOKEN_EXPIRATION_ENABLED", "false").lower() == "true"
TOKEN_EXPIRATION_MINUTES = int(os.getenv("TOKEN_EXPIRATION_MINUTES", 30))

# Configure logging
LOG_DIR = "/app/llm-setup/logs"
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
logging.basicConfig(
    filename=os.path.join(LOG_DIR, 'llm_api.log'),
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

app = FastAPI()

class GenerateRequest(BaseModel):
    text: str
    max_tokens: int = 512
    temperature: float = 0.7
    top_p: Optional[float] = 0.9  # Default: Nucleus Sampling
    top_k: Optional[int] = 50     # Default: Top-k Sampling
    repetition_penalty: Optional[float] = 1.0  # No penalty by default
    stop_tokens: Optional[List[str]] = None    # Custom stop tokens
    presence_penalty: Optional[float] = None   # Encourage new tokens
    triggers: Optional[List[str]] = None       # Custom control triggers

@app.post("/generate")
async def generate_text(query: GenerateRequest):
    profiler = cProfile.Profile()
    profiler.enable()
    try:
        logging.info(f"Request received: {query}")
        response = model(
            query.text,
            max_tokens=query.max_tokens,
            temperature=query.temperature,
            top_p=query.top_p,
            top_k=query.top_k,
            stop=query.stop_tokens or ["</s>", "Human:", "Assistant:"]
        )
        profiler.disable()
        profiler.print_stats(sort="cumtime")
        return {"response": response["choices"][0]["text"]}
    except Exception as e:
        logging.error(f"Error generating response: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

MODEL_PATH = "/app/llm-setup/models/qwen2.5-3b-instruct-q8_0.gguf"
model = Llama(model_path=MODEL_PATH, n_threads=N_THREADS, n_batch=N_BATCH, n_ctx=N_CTX)
EOL

# Ensure no existing process is using port 8082
echo "Checking for processes using port 8082..."
if lsof -i:8082 > /dev/null; then
    echo "Killing existing process on port 8082..."
    lsof -i:8082 -t | xargs kill -9
else
    echo "No process is using port 8082."
fi

# Start the Python server using nohup
echo "Starting the LLM server..."
nohup bash -c "cd $SETUP_DIR && source venv/bin/activate && uvicorn main:app --host 0.0.0.0 --port 8082" > "$SETUP_DIR/logs/server.log" 2>&1 &

# Create GPU monitoring script
GPU_MONITOR_SCRIPT="$SETUP_DIR/gpu_monitor.sh"
cat > "$GPU_MONITOR_SCRIPT" << 'EOS'
#!/bin/bash
LOG_FILE="/app/llm-setup/logs/gpu_monitor.log"
echo "Starting GPU monitoring at $(date)" > $LOG_FILE
while true; do
    nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.free,memory.total --format=csv,noheader >> $LOG_FILE
    sleep 10
done
EOS
chmod +x "$GPU_MONITOR_SCRIPT"
echo "GPU monitoring script created at $GPU_MONITOR_SCRIPT. You can run it separately."
