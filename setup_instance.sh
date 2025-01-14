#!/bin/bash

# Config
LIBRECHAT_DIR="/app/librechat"
LOG_DIR="/app/logs"
MODEL_DIR="/app/models"
LIBRECHAT_SETTINGS_FILE="$LIBRECHAT_DIR/config/settings.json"
DEFAULT_USER_EMAIL=${DEFAULT_USER_EMAIL:-"admin@librechat.com"}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-"admin123"}
MODEL_URL="https://huggingface.co/lmstudio-community/Llama-3.3-70B-Instruct-GGUF/resolve/main/Llama-3.3-70B-Instruct-Q8_0.gguf"
LIBRECHAT_PORT=${LIBRECHAT_PORT:-3000}
mkdir -p "$LOG_DIR" "$MODEL_DIR" "$LIBRECHAT_DIR" "/app/config"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/setup.log"; }

log "Starting setup process..."

# Install necessary tools
apt-get update && apt-get upgrade -y
apt-get install -y python3-pip python3-dev build-essential nvidia-cuda-toolkit curl git nodejs npm

# Install Python dependencies
log "Installing Python dependencies..."
pip3 install --no-cache-dir torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 \
    transformers==4.36.2 huggingface_hub>=0.19.3,<1.0

# Ensure huggingface-cli is available
if ! command -v huggingface-cli &>/dev/null; then
    log "huggingface-cli not found. Check your Python environment."
    exit 1
fi

# Detect GPUs and configure parallelism
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
log "Detected $GPU_COUNT GPU(s)."
export TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-$GPU_COUNT}"

# Configure Hugging Face CLI for authentication
HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN:-""}
if [[ -z "$HUGGINGFACE_TOKEN" ]]; then
    log "Hugging Face token is required. Please set HUGGINGFACE_TOKEN in your environment."
    exit 1
fi
echo "$HUGGINGFACE_TOKEN" | huggingface-cli login --token

# Clone LibreChat repository
log "Cloning LibreChat repository..."
if [ -d "$LIBRECHAT_DIR" ]; then
    log "Existing LibreChat directory found. Removing..."
    rm -rf "$LIBRECHAT_DIR"
fi

if git clone https://github.com/danny-avila/LibreChat.git "$LIBRECHAT_DIR"; then
    log "Successfully cloned LibreChat."
else
    log "Failed to clone LibreChat."; exit 1;
fi

# Install LibreChat dependencies
log "Installing LibreChat dependencies..."
cd "$LIBRECHAT_DIR"
npm install || { log "Failed to install LibreChat dependencies."; exit 1; }

# Configure LibreChat settings
log "Configuring LibreChat settings..."
cat > "$LIBRECHAT_SETTINGS_FILE" <<EOL
{
  "defaultUser": {
    "email": "$DEFAULT_USER_EMAIL",
    "password": "$DEFAULT_USER_PASSWORD"
  },
  "modelPath": "$MODEL_DIR/Llama-3.3-70B-Instruct-Q8_0.gguf",
  "serverPort": $LIBRECHAT_PORT
}
EOL
log "LibreChat configuration updated: $LIBRECHAT_SETTINGS_FILE"

# Download the model
log "Downloading LLaMA model..."
if [ ! -f "$MODEL_DIR/Llama-3.3-70B-Instruct-Q8_0.gguf" ]; then
    wget -q --show-progress -P "$MODEL_DIR" "$MODEL_URL" || { log "Failed to download the model."; exit 1; }
    log "Model downloaded successfully."
else
    log "Model already exists. Skipping download."
fi

# Restart LibreChat to apply settings
log "Restarting LibreChat..."
pkill -f "npm start" || log "No existing LibreChat process found."
nohup npm start -- --port $LIBRECHAT_PORT > "$LOG_DIR/librechat_$(date +'%Y%m%d_%H%M%S').log" 2>&1 &
log "LibreChat restarted on port $LIBRECHAT_PORT."

log "Setup complete. Default user: $DEFAULT_USER_EMAIL / $DEFAULT_USER_PASSWORD"
