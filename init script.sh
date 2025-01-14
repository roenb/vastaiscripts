#!/bin/bash

# Configuration
REPO_URL="git@github.com:roenb/vastaiscripts.git"
CLONE_DIR="/app/vastaiscripts"
LOG_DIR="/app/logs"
FULL_SCRIPT="setup_instance.sh" # Replace with the desired script name
mkdir -p "$LOG_DIR"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/startup.log"; }

log "Starting lightweight setup..."

# Install essential tools
apt-get update && apt-get install -y git curl || { log "Failed to install essential tools."; exit 1; }

# Clone the repository
log "Cloning the repository..."
if git clone "$REPO_URL" "$CLONE_DIR"; then
    log "Repository cloned successfully."
else
    log "Failed to clone repository."; exit 1;
fi

# Execute the full setup script
FULL_SCRIPT_PATH="$CLONE_DIR/$FULL_SCRIPT"
if [[ -f "$FULL_SCRIPT_PATH" ]]; then
    log "Running the full setup script: $FULL_SCRIPT"
    chmod +x "$FULL_SCRIPT_PATH"
    bash "$FULL_SCRIPT_PATH"
else
    log "Setup script not found: $FULL_SCRIPT_PATH"; exit 1;
fi

log "Lightweight setup complete."
