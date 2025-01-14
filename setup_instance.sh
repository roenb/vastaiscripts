#!/bin/bash

# Config
LIBRECHAT_DIR="/app/librechat"
LOG_DIR="/app/logs"
MODEL_DIR="/app/models"
LIBRECHAT_SETTINGS_FILE="$LIBRECHAT_DIR/config/settings.json"
DEFAULT_USER_EMAIL=${DEFAULT_USER_EMAIL:-"admin@librechat.com"}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-"admin123"}
LIBRECHAT_PORT=${LIBRECHAT_PORT:-3000}
PYTHON_SCRIPT_PATH="/app/vastaiscripts/download_models.py"
HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN:-""}

mkdir -p "$LOG_DIR" "$MODEL_DIR" "$LIBRECHAT_DIR" "/app/config"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/setup.log"; }

log "Starting setup process..."

# Install necessary tools
log "Installing system tools..."
apt-get update && apt-get upgrade -y
apt-get install -y python3-pip python3-dev build-essential nvidia-cuda-toolkit curl git nodejs npm || { log "Failed to install system tools."; exit 1; }

# Install Python dependencies
log "Installing Python dependencies..."
pip3 install --no-cache-dir torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 \
    transformers==4.36.2 huggingface-hub==0.19.3 || { log "Failed to install Python dependencies."; exit 1; }

# Ensure huggingface-cli is available
log "Checking for Hugging Face CLI..."
if ! command -v huggingface-cli &>/dev/null; then
    log "huggingface-cli not found. Installing Hugging Face CLI..."
    python3 -m pip install huggingface-hub==0.19.3 || { log "Failed to install huggingface-hub."; exit 1; }
fi

log "huggingface-cli is available."

# Configure Hugging Face CLI for authentication
if [[ -z "$HUGGINGFACE_TOKEN" ]]; then
    log "Hugging Face token is required. Please set HUGGINGFACE_TOKEN in your environment."
    exit 1
fi
echo "$HUGGINGFACE_TOKEN" | huggingface-cli login --token || { log "Failed to authenticate with Hugging Face."; exit 1; }

# Detect GPUs and configure parallelism
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
log "Detected $GPU_COUNT GPU(s)."
export TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-$GPU_COUNT}"

# Clone the Vast.ai scripts repository (if needed)
REPO_URL="https://github.com/roenb/vastaiscripts.git"
SCRIPTS_DIR="/app/vastaiscripts"
if [ ! -d "$SCRIPTS_DIR" ]; then
    log "Cloning Vast.ai scripts repository..."
    if git clone "$REPO_URL" "$SCRIPTS_DIR"; then
        log "Successfully cloned Vast.ai scripts repository."
    else
        log "Failed to clone Vast.ai scripts repository."; exit 1;
    fi
else
    log "Vast.ai scripts repository already exists. Skipping clone."
fi

# Download the models using Python script
log "Downloading models using Python script..."
python3 "$PYTHON_SCRIPT_PATH" || { log "Failed to download models."; exit 1; }

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
  "modelPath": "$MODEL_DIR/Llama-3.3-70B-Instruct-Q8_0-00001-of-00002.gguf",
  "serverPort": $LIBRECHAT_PORT
}
EOL
log "LibreChat configuration updated: $LIBRECHAT_SETTINGS_FILE"

# Restart LibreChat to apply settings
log "Restarting LibreChat..."
pkill -f "npm start" || log "No existing LibreChat process found."
nohup npm start -- --port $LIBRECHAT_PORT > "$LOG_DIR/librechat_$(date +'%Y%m%d_%H%M%S').log" 2>&1 &
LIBRECHAT_PID=$!

# Verify LibreChat restart
sleep 5
if ps -p $LIBRECHAT_PID > /dev/null; then
    log "LibreChat restarted successfully on port $LIBRECHAT_PORT."
else
    log "LibreChat failed to start. Check logs at $LOG_DIR/librechat_$(date +'%Y%m%d_%H%M%S').log."
    exit 1
fi

log "Setup complete. Default user: $DEFAULT_USER_EMAIL / $DEFAULT_USER_PASSWORD"
