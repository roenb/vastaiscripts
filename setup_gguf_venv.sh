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
apt-get install -y python3-pip python3-venv wget lsof || { echo "Package installation failed"; exit 1; }

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
pip install fastapi uvicorn pydantic llama-cpp-python pyjwt || { echo "Failed to install dependencies"; exit 1; }

# Generate a default token and save it to oauth_tokens.txt
generate_default_token() {
    echo "Generating default OAuth token..."
    local default_token=$(python3 -c "import jwt; from datetime import datetime, timedelta; print(jwt.encode({'exp': datetime.utcnow() + timedelta(minutes=30), 'iat': datetime.utcnow(), 'sub': 'default_user'}, 'SmartTasks', algorithm='HS256'))")
    echo "$default_token" > "$SETUP_DIR/oauth_tokens.txt"
    echo "Default OAuth token generated and saved to $SETUP_DIR/oauth_tokens.txt"
}
generate_default_token

# Create main Python script
cat > "$SETUP_DIR/main.py" << 'EOL'
import logging
import os
from fastapi import FastAPI, HTTPException, Depends, Header
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
        file.write(token.strip() + "\n")

def verify_token(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        logging.error("Authorization header is missing or malformed")
        raise HTTPException(status_code=401, detail="Missing or malformed authorization header")
    token = authorization.split("Bearer ")[1].strip()
    try:
        logging.info(f"Received token: {token}")
        # Decode the token
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        logging.info(f"Decoded payload: {payload}")

        # Verify the token exists in the oauth_tokens.txt
        if os.path.exists(TOKEN_FILE):
            with open(TOKEN_FILE, "r") as file:
                valid_tokens = [line.strip() for line in file.readlines()]
                logging.info(f"Valid tokens: {valid_tokens}")

                if token not in valid_tokens:
                    logging.warning("Token not found in oauth_tokens.txt")
                    raise HTTPException(status_code=401, detail="Invalid token")
        else:
            logging.error("oauth_tokens.txt file not found")
            raise HTTPException(status_code=500, detail="Token file missing")

        return payload

    except jwt.ExpiredSignatureError:
        logging.error("Token has expired")
        raise HTTPException(status_code=401, detail="Token has expired")
    except jwt.InvalidTokenError as e:
        logging.error(f"Invalid token error: {e}")
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
    logging.info("Received request at /generate")
    logging.info(f"Request body: {query}")
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

# Ensure no existing process is using port 8082
echo "Checking for processes using port 8082..."
if lsof -i:8082 > /dev/null; then
    echo "Killing existing process on port 8082..."
    lsof -i:8082 -t | xargs kill -9 || echo "Failed to kill process. Please check manually."
else
    echo "No process is using port 8082."
fi

# Start the Python server using nohup
echo "Starting the LLM server..."
nohup bash -c "cd $SETUP_DIR && source venv/bin/activate && uvicorn main:app --host 0.0.0.0 --port 8082" > "$SETUP_DIR/logs/server.log" 2>&1 &

# Check if the application is running on the desired port
echo "Checking if the application is running on port 8082..."
sleep 2
if lsof -i:8082 > /dev/null; then
    echo "Application is running on port 8082."
    echo "Logs are available at $SETUP_DIR/logs/server.log"
else
    echo "Application is NOT running on port 8082. Check the logs at $SETUP_DIR/logs/server.log for errors."
fi
