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

# Function to get memory information in MB
get_memory_info() {
    total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    available_mem=$(free -m | awk '/^Mem:/ {print $7}')
    echo "$total_mem $available_mem"
}

# Get memory values
read total_mem available_mem <<< $(get_memory_info)

# Log memory information
echo "System Memory Information:"
echo "Total Memory: ${total_mem}MB"
echo "Available Memory: ${available_mem}MB"

# Install required packages
echo "Installing required packages..."
if [ "$EUID" -eq 0 ]; then
    apt-get update
    apt-get install -y python3-pip python3-venv wget
else
    sudo apt-get update
    sudo apt-get install -y python3-pip python3-venv wget
fi

# Download the Qwen model
echo "Downloading Qwen 2.5 3B GGUF model..."
cd "$SETUP_DIR/models"
if [ ! -f qwen2.5-3b-instruct-q8_0.gguf ]; then
    wget -O qwen2.5-3b-instruct-q8_0.gguf https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q8_0.gguf
    if [ $? -ne 0 ]; then
        echo "Error downloading Qwen model. Please check the URL or your internet connection."
        exit 1
    fi
else
    echo "Model file already exists. Skipping download."
fi

# Remove existing virtual environment if it exists
echo "Cleaning up existing virtual environment..."
if [ -d "$SETUP_DIR/venv" ]; then
    rm -rf "$SETUP_DIR/venv"
fi

# Create Python virtual environment
echo "Creating Python virtual environment..."
python3 -m venv "$SETUP_DIR/venv"
source "$SETUP_DIR/venv/bin/activate"

# Install Python dependencies
pip install --upgrade pip
pip install fastapi uvicorn pydantic llama-cpp-python pyjwt

# Generate a default token and save it to oauth_tokens.txt
generate_default_token() {
    echo "Generating default OAuth token..."
    local default_token=$(python3 -c "import jwt; from datetime import datetime, timedelta; print(jwt.encode({'exp': datetime.utcnow() + timedelta(minutes=30), 'iat': datetime.utcnow(), 'sub': 'default_user'}, 'supersecretkey', algorithm='HS256'))")
    echo "$default_token" > "$SETUP_DIR/oauth_tokens.txt"
    echo "Default OAuth token generated and saved to $SETUP_DIR/oauth_tokens.txt"
}

generate_default_token

# Create main Python script
cat > "$SETUP_DIR/main.py" << 'EOL'
import logging
import os
from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel
from llama_cpp import Llama
from datetime import datetime, timedelta
import jwt

# Ensure logs directory exists
LOG_DIR = "/app/llm-setup/logs"
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)

# JWT Config
SECRET_KEY = "supersecretkey"
ALGORITHM = "HS256"
TOKEN_EXPIRATION_MINUTES = 30
TOKEN_FILE = "/app/llm-setup/oauth_tokens.txt"

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

# Configure logging
logging.basicConfig(
    filename=os.path.join(LOG_DIR, 'llm_api.log'),
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

app = FastAPI()

MODEL_PATH = "/app/llm-setup/models/qwen2.5-3b-instruct-q8_0.gguf"
if not os.path.exists(MODEL_PATH):
    logging.error(f"Model file not found at {MODEL_PATH}")
    raise FileNotFoundError(f"Model file not found at {MODEL_PATH}")

try:
    model = Llama(
        model_path=MODEL_PATH,
        n_threads=4,
        n_batch=512,
        n_ctx=2048
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
        response = model(
            query.text,
            max_tokens=query.max_tokens,
            temperature=query.temperature,
            stop=["</s>", "Human:", "Assistant:"],
            echo=False
        )
        return {"response": response["choices"][0]["text"]}
    except Exception as e:
        logging.error(f"Error generating response: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/token")
async def generate_token():
    token = create_token()
    return {"token": token}
EOL

# Ensure correct permissions
if [ "$EUID" -eq 0 ]; then
    chown -R $ACTUAL_USER:$ACTUAL_USER "$SETUP_DIR"
fi

# Start the Python server directly
echo "Starting the LLM server..."
source "$SETUP_DIR/venv/bin/activate"
exec python3 "$SETUP_DIR/main.py"
