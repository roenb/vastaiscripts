import os
import sys
import shutil
from huggingface_hub import hf_hub_download

# Config
LOG_FILE = "/app/logs/download_models.log"
MODEL_FILES = [
    {
        "repo_id": "lmstudio-community/Llama-3.3-70B-Instruct-GGUF",
        "filename": "Llama-3.3-70B-Instruct-Q8_0-00001-of-00002.gguf",
        "target_folder": "/app/models",
    },
    {
        "repo_id": "lmstudio-community/Llama-3.3-70B-Instruct-GGUF",
        "filename": "Llama-3.3-70B-Instruct-Q8_0-00002-of-00002.gguf",
        "target_folder": "/app/models",
    },
]

# Logging function
def log(message):
    """
    Append a log message to the log file and print it.
    """
    with open(LOG_FILE, "a") as log_file:
        log_file.write(message + "\n")
    print(message)

# Download and save model files
def download_and_save_model(repo_id, filename, target_folder):
    """
    Download the model from HuggingFace Hub and save it to the specified folder.
    """
    try:
        log(f"Starting download of {filename} from {repo_id}")
        file_path = hf_hub_download(
            repo_id=repo_id,
            filename=filename,
            cache_dir="./cache_folder",
        )
        target_path = os.path.join(target_folder, filename)

        # Check if file already exists
        if os.path.exists(target_path):
            log(f"File already exists at {target_path}. Skipping download.")
            return

        # Copy file to target location
        log(f"Copying {file_path} to {target_path}")
        shutil.copy(file_path, target_path)
        log(f"Successfully saved {filename} to {target_path}")
    except Exception as e:
        log(f"Error downloading {filename}: {str(e)}")

if __name__ == "__main__":
    os.makedirs("/app/logs", exist_ok=True)
    os.makedirs("/app/models", exist_ok=True)

    log("Download script started.")
    for model in MODEL_FILES:
        download_and_save_model(
            repo_id=model["repo_id"],
            filename=model["filename"],
            target_folder=model["target_folder"],
        )
    log("Download script finished.")
