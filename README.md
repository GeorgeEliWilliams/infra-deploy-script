# Automated Remote Deployment Script (`deploy.sh`)

## Overview

This project provides an **automated end-to-end deployment solution** using a Bash script that securely clones a GitHub repository, deploys it to a remote Ubuntu EC2 instance, builds a Docker image, runs the container, and configures **Nginx as a reverse proxy** to serve the application publicly.

It is designed for AWS EC2 environments but can run on any Linux-based host with SSH access.

---

## 🚀 Features

✅ **Interactive Setup**
- Prompts the user for repository, SSH, and deployment details.
- Validates all inputs (repo URL, branch, port, key path, etc).

✅ **Automated Deployment Workflow**
- Clones or updates the specified Git repository.
- Builds a Docker image remotely and runs it as a container.
- Configures **Nginx reverse proxy** from port `80` → app internal port.
- Performs deployment validation via Docker and HTTP checks.

✅ **Error Handling & Logging**
- Uses `set -euo pipefail`, `trap`, and dedicated `log()` / `err()` functions.
- Logs all activity to timestamped `deploy_YYYYMMDD_HHMMSS.log` files.

✅ **Idempotency**
- Cleans up old containers, images, and Nginx configs before redeploying.
- Skips redundant installations if Docker or Nginx already exist.

✅ **Cleanup Flag**
- `--cleanup` option removes deployed containers, images, Nginx configs, and app files from the remote host.

---

## 🧠 Requirements

### Local Machine
- Bash shell (Linux/macOS)
- SSH access to a remote server
- Git installed (`git --version`)
- Optional: `rsync` (for faster file transfers)

### Remote Server (e.g., AWS EC2 Ubuntu instance)
- Ubuntu 20.04+ recommended
- SSH key-based authentication enabled
- Internet access for package installation
- (The script installs Docker and Nginx automatically if missing)

---

## ⚙️ Usage

### 1️⃣ Make the Script Executable
```bash
chmod +x deploy.sh
```

### 2️⃣ Run the Script
```bash
./deploy.sh
```

The script will interactively ask for:
- Git repository URL
- Personal Access Token (optional)
- Branch name
- Remote SSH username
- Remote server IP
- SSH key path
- Application internal port
- Local clone directory

### 3️⃣ Confirm and Deploy
After reviewing the summary, type y to confirm.
The script will:

- Clone or update your repo locally.

- Upload files to the EC2 instance.

- Install Docker and Nginx (if missing).

- Build and run the Docker container.

- Configure Nginx to proxy traffic on port 80 to your container port.

- Validate the deployment automatically.
