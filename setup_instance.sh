#!/bin/bash

# Config
LIBRECHAT_DIR="/app/librechat"
LOG_DIR="/app/logs"
MODEL_DIR="/app/models"
LIBRECHAT_SETTINGS_FILE="$LIBRECHAT_DIR/config/settings.json"
DEFAULT_USER_EMAIL=${DEFAULT_USER_EMAIL:-"admin@librechat.com"}
DEFAULT_USER_PASSWORD=${DEFAULT_USER_PASSWORD:-"admin123"}
LIBRECHAT_PORT=${LIBRECHAT_PORT:-3000}
MODELS_LIST=${MODELS_LIST:-"lmstudio-community/Llama-3.3-70B-Instruct-GGUF"}
QUANTIZATION=${QUANTIZATION:-"Q8_0"}
HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN:-""}
ALLOW_GPU_OVERCOMMIT=${ALLOW_GPU_OVERCOMMIT:-false}

mkdir -p "$LOG_DIR" "$MODEL_DIR" "$LIBRECHAT_DIR" "/app/config"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/setup.log"; }

log "Starting dynamic multi-model, multi-GPU setup process..."

# Install necessary tools
log "Installing system tools..."
apt-get update && apt-get upgrade -y
apt-get install -y python3-pip python3-dev build-essential nvidia-cuda-toolkit curl git nodejs npm || { log "Failed to install system tools."; exit 1; }

# Install Python dependencies
log "Installing Python dependencies..."
pip3 install --no-cache-dir torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 huggingface-hub==0.19.3 || { log "Failed to install Python dependencies."; exit 1; }

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

# Detect GPUs and VRAM
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
log "Detected $GPU_COUNT GPU(s)."

GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{SUM+=$1} END {print SUM}')
log "Total GPU VRAM available: ${GPU_VRAM}MB"

# Parse MODELS_LIST and download models
log "Parsing models list..."
IFS=',' read -r -a MODELS <<< "$MODELS_LIST"

for MODEL in "${MODELS[@]}"; do
    # Extract repo and quantization
    if [[ $MODEL == *":"* ]]; then
        REPO_ID=$(echo "$MODEL" | cut -d':' -f1)
        MODEL_QUANT=$(echo "$MODEL" | cut -d':' -f2)
    else
        REPO_ID=$MODEL
        MODEL_QUANT=$QUANTIZATION
    fi

    log "Processing model: $REPO_ID with quantization: $MODEL_QUANT"

    # Fetch all relevant files
    MODEL_FILES=$(python3 - <<EOF
from huggingface_hub import hf_hub_list
repo_id = "$REPO_ID"
quant_level = "$MODEL_QUANT"
files = hf_hub_list(repo_id)
filtered_files = [f.rfilename for f in files if quant_level in f.rfilename]
print(",".join(filtered_files))
EOF
)

    IFS=',' read -r -a FILES <<< "$MODEL_FILES"
    for FILE in "${FILES[@]}"; do
        log "Downloading $FILE..."
        python3 -m huggingface_hub.cli.hf_hub_download --repo-id "$REPO_ID" --filename "$FILE" --local-dir "$MODEL_DIR/$REPO_ID" || {
            log "Failed to download $FILE for $REPO_ID"; exit 1;
        }
    done

    log "Successfully downloaded all files for $REPO_ID"
done

# Determine deployment strategy
TOTAL_MODEL_SIZE=$(du -sm "$MODEL_DIR" | awk '{print $1}')
log "Total model size: ${TOTAL_MODEL_SIZE}MB"

if [[ $TOTAL_MODEL_SIZE -le $GPU_VRAM ]]; then
    if [[ $GPU_COUNT -eq 1 ]]; then
        log "Use case: Single GPU, single model."
        export TENSOR_PARALLEL_SIZE=1
    else
        log "Use case: Multi-GPU, single model split across GPUs."
        export TENSOR_PARALLEL_SIZE=$GPU_COUNT
    fi
else
    log "Use case: Multiple small models across GPUs."
    export TENSOR_PARALLEL_SIZE=1
fi

# Start the model server
log "Starting model server..."
nohup python3 -m vllm.entrypoints.openai.api_server \
    --host 0.0.0.0 --port $LIBRECHAT_PORT \
    --model-dir "$MODEL_DIR" \
    --tensor-parallel-size $TENSOR_PARALLEL_SIZE \
    --max-num-batched-tokens 8192 \
    --max-num-seqs 16 > "$LOG_DIR/model_server_$(date +'%Y%m%d_%H%M%S').log" 2>&1 &
SERVER_PID=$!

# Verify the server launch
sleep 5
if ps -p $SERVER_PID > /dev/null; then
    log "Model server started successfully on port $LIBRECHAT_PORT using $TENSOR_PARALLEL_SIZE GPUs."
else
    log "Model server failed to start. Check logs at $LOG_DIR/model_server_$(date +'%Y%m%d_%H%M%S').log."
    exit 1
fi

# Clone and configure LibreChat
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

log "Installing LibreChat dependencies..."
cd "$LIBRECHAT_DIR"
npm install || { log "Failed to install LibreChat dependencies."; exit 1; }

# Configure LibreChat default user
log "Configuring LibreChat settings..."
cat > "$LIBRECHAT_SETTINGS_FILE" <<EOL
{
  "defaultUser": {
    "email": "$DEFAULT_USER_EMAIL",
    "password": "$DEFAULT_USER_PASSWORD"
  },
  "modelPath": "$MODEL_DIR",
  "serverPort": $LIBRECHAT_PORT
}
EOL
log "LibreChat configuration updated: $LIBRECHAT_SETTINGS_FILE"

# Start LibreChat
log "Starting LibreChat..."
nohup npm start -- --port $LIBRECHAT_PORT > "$LOG_DIR/librechat_$(date +'%Y%m%d_%H%M%S').log" 2>&1 &
LIBRECHAT_PID=$!

# Verify LibreChat launch
sleep 5
if ps -p $LIBRECHAT_PID > /dev/null; then
    log "LibreChat started successfully on port $LIBRECHAT_PORT."
else
    log "LibreChat failed to start. Check logs at $LOG_DIR/librechat_$(date +'%Y%m%d_%H%M%S').log."
    exit 1
fi

log "Setup complete. Default user: $DEFAULT_USER_EMAIL / $DEFAULT_USER_PASSWORD"
