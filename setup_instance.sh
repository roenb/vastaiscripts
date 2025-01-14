#!/bin/bash

# Config
LIBRECHAT_DIR="/app/librechat"
LOG_DIR="/app/logs"
MODEL_DIR="/app/models"
mkdir -p "$LOG_DIR" "$MODEL_DIR" "$LIBRECHAT_DIR" "/app/config"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/setup.log"; }

log "Setting up instance..."
apt-get update && apt-get upgrade -y
apt-get install -y python3-pip python3-dev build-essential nvidia-cuda-toolkit nodejs npm

# Install dependencies
pip3 install --no-cache-dir torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 transformers==4.36.2 \
    vllm==0.2.7 llama-cpp-python==0.1.77 huggingface_hub==0.17.1

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
git clone https://github.com/danny-avila/LibreChat.git "$LIBRECHAT_DIR" || { log "Failed to clone LibreChat."; exit 1; }

# Install LibreChat dependencies
log "Installing LibreChat dependencies..."
cd "$LIBRECHAT_DIR"
npm install

log "Setup complete."
