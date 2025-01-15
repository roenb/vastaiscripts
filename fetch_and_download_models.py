import os
from huggingface_hub import HfApi, hf_hub_download
import threading

# Load environment variables
REPO_ID = os.getenv("MODEL_REPO_ID", "lmstudio-community/Llama-3.3-70B-Instruct-GGUF")
QUANTIZATION = os.getenv("QUANTIZATION", "Q8_0")
TARGET_FOLDER = os.getenv("MODEL_DIR", "/app/models")
LOG_FILE = "/app/logs/download_models.log"

# Ensure target directory exists
os.makedirs(TARGET_FOLDER, exist_ok=True)

# Logging function
def log(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{message}\n")
    print(message)

# Fetch and filter model files
def fetch_model_files(repo_id, quantization):
    try:
        log(f"Fetching file list from repository: {repo_id}")
        api = HfApi()
        files = api.list_repo_files(repo_id)

        # Filter files matching the quantization pattern
        quantized_files = [file for file in files if quantization in file and file.endswith(".gguf")]
        log(f"Found {len(quantized_files)} files for quantization level {quantization}.")
        return quantized_files
    except Exception as e:
        log(f"Failed to fetch files from repository: {str(e)}")
        return []

# Download a single file
def download_file(repo_id, filename, target_folder):
    try:
        log(f"Starting download for {filename}")
        file_path = hf_hub_download(repo_id=repo_id, filename=filename, cache_dir="./cache_folder")
        target_path = os.path.join(target_folder, os.path.basename(filename))

        # Skip download if file already exists
        if os.path.exists(target_path):
            log(f"File already exists: {target_path}. Skipping.")
            return

        # Move the file to the target location
        log(f"Copying {file_path} to {target_path}")
        os.rename(file_path, target_path)
        log(f"Successfully downloaded and saved {filename} to {target_path}")
    except Exception as e:
        log(f"Failed to download {filename}: {str(e)}")

# Parallel download handler
def parallel_download(repo_id, file_list, target_folder):
    threads = []
    for filename in file_list:
        thread = threading.Thread(target=download_file, args=(repo_id, filename, target_folder))
        threads.append(thread)
        thread.start()

    for thread in threads:
        thread.join()

if __name__ == "__main__":
    log("Starting GGUF model download process...")

    # Fetch the list of files for the specified quantization
    quantized_files = fetch_model_files(REPO_ID, QUANTIZATION)

    if quantized_files:
        # Download files in parallel
        parallel_download(REPO_ID, quantized_files, TARGET_FOLDER)
    else:
        log(f"No files found for quantization level {QUANTIZATION}.")

    log("GGUF model download process completed.")
