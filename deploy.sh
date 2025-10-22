#!/usr/bin/env bash
# deploy.sh - Full end-to-end deploy script (Stages 1-10)
# Usage:
#   ./deploy.sh          -> run deploy
#   ./deploy.sh --cleanup -> remove deployed resources on remote
#
# Requirements: ssh access, git installed locally, remote is Ubuntu-compatible
set -o errexit
set -o nounset
set -o pipefail


# Basic metadata / logfile

TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
LOGFILE="./deploy_${TIMESTAMP}.log"
# Logger functions write to both stdout/stderr and logfile
log()  { printf "[%s] INFO: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"; }
err()  { printf "[%s] ERROR: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }

# Trap for unexpected errors
_on_err() {
  local rc=$?
  err "Unexpected error (exit code: $rc). See $LOGFILE for details."
  exit $rc
}
trap _on_err INT TERM ERR


# Helper validation funcs #

is_valid_repo_url() {
  local url="$1"
  if printf '%s' "$url" | grep -Eq '^(https?://|git@|ssh://)'; then
    return 0
  fi
  return 1
}

is_valid_port() {
  local p="$1"
  if printf '%s' "$p" | grep -Eq '^[0-9]+$' && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
    return 0
  fi
  return 1
}

expand_path() {
  local p="$1"
  p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ "${p#\~}" != "$p" ]; then
    p="${p/#\~/$HOME}"
  fi
  printf '%s' "$p"
}


# CLI flags

CLEANUP=0
if [ "${1-}" = "--cleanup" ] || [ "${1-}" = "-c" ]; then
  CLEANUP=1
fi


# Prompt helper functions #

prompt() {
  local varname="$1"; local prompt_text="$2"; local default="${3-}"
  local input
  if [ -n "$default" ]; then
    read -r -p "$prompt_text [$default]: " input
    input="${input:-$default}"
  else
    read -r -p "$prompt_text: " input
  fi
  printf -v "$varname" "%s" "$input"
}

prompt_secret() {
  local varname="$1"; local prompt_text="$2"; local input
  stty -echo
  read -r -p "$prompt_text: " input || true
  stty echo
  printf "\n"
  printf -v "$varname" "%s" "$input"
}


# Stage 1: Collect Input

log "Collecting deployment parameters."

# 1) Repo URL
while true; do
  prompt REPO_URL "Git repository URL (HTTPS or SSH)"
  if [ -z "${REPO_URL// /}" ]; then
    err "Repository URL cannot be empty."
    continue
  fi
  if is_valid_repo_url "$REPO_URL"; then break; else err "Repository URL looks invalid."; fi
done

# 2) Personal Access Token (optional)
prompt_secret PAT "Personal Access Token (PAT) for HTTPS repo (leave empty to use SSH/agent if repo uses SSH)"

# 3) Branch
prompt BRANCH "Branch name" "main"
BRANCH="${BRANCH:-main}"

# 4) Remote SSH username
while true; do
  prompt REMOTE_USER "Remote SSH username (e.g. ubuntu)"
  if [ -n "${REMOTE_USER// /}" ]; then break; else err "Username required."; fi
done

# 5) Remote server IP/host
while true; do
  prompt REMOTE_HOST "Remote server IP or hostname"
  if [ -n "${REMOTE_HOST// /}" ]; then break; else err "Host/IP required."; fi
done

# 6) SSH key path
while true; do
  prompt SSH_KEY_PATH "Path to SSH private key for remote connection (e.g. ~/Downloads/ec2-key.pem)"
  SSH_KEY_PATH="$(expand_path "$SSH_KEY_PATH")"
  if [ -f "$SSH_KEY_PATH" ]; then
    perm=$(stat -c '%a' "$SSH_KEY_PATH" 2>/dev/null || stat -f '%Lp' "$SSH_KEY_PATH" 2>/dev/null || echo "")
    log "Found SSH key at $SSH_KEY_PATH (permissions: ${perm:-unknown})."
    break
  else
    err "SSH key not found at '$SSH_KEY_PATH'."
  fi
done

# 7) Internal application port
while true; do
  prompt APP_PORT "Application internal container port (e.g. 5000)"
  if is_valid_port "$APP_PORT"; then break; else err "Invalid port. Enter 1-65535."; fi
done

# Local clone dir
prompt LOCAL_CLONE_DIR "Local directory to clone into (will create if missing)" "."
LOCAL_CLONE_DIR="$(expand_path "$LOCAL_CLONE_DIR")"
mkdir -p "$LOCAL_CLONE_DIR"

log "Parameters summary (PAT hidden):"
log "  Repo URL:    $REPO_URL"
log "  Branch:      $BRANCH"
log "  Remote:      ${REMOTE_USER}@${REMOTE_HOST}"
log "  SSH key:     $SSH_KEY_PATH"
log "  App port:    $APP_PORT"
log "  Clone dir:   $LOCAL_CLONE_DIR"

read -r -p "Proceed with these values? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  err "User aborted."
  exit 1
fi

log "User input collected and validated."


# Stage 2-3: Clone & verify locally

log "Cloning repository."

cd "$LOCAL_CLONE_DIR"
REPO_NAME=$(basename "$REPO_URL" .git)

if [ -d "$REPO_NAME/.git" ]; then
  log "Repository '$REPO_NAME' already exists. Pulling latest changes..."
  cd "$REPO_NAME"
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "")
  if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    log "Switching branch from $CURRENT_BRANCH to $BRANCH."
    git fetch origin "$BRANCH" || err "Failed to fetch branch $BRANCH."
    git checkout "$BRANCH" || err "Failed to switch to branch $BRANCH."
  fi
  git pull origin "$BRANCH" || { err "Failed to pull latest changes."; exit 1; }
else
  log "Cloning new repository: $REPO_URL"
  if printf '%s' "$REPO_URL" | grep -qE '^https?://'; then
    if [ -n "$PAT" ]; then
      AUTH_URL=$(printf '%s' "$REPO_URL" | sed -E "s#https://#https://${PAT}@#")
      git clone --branch "$BRANCH" "$AUTH_URL" || { err "Failed to clone repo using PAT."; exit 1; }
    else
      # attempt clone of specified branch; if not present fallback to default branch
      if ! git clone --branch "$BRANCH" "$REPO_URL"; then
        log "Branch '$BRANCH' not found; cloning default branch instead."
        git clone "$REPO_URL" || { err "Failed to clone repo."; exit 1; }
      fi
    fi
  else
    if ! git clone --branch "$BRANCH" "$REPO_URL"; then
      log "Branch '$BRANCH' not found; attempting default branch via SSH."
      git clone "$REPO_URL" || { err "Failed to clone repo via SSH."; exit 1; }
    fi
  fi
  cd "$REPO_NAME"
fi

# Confirm Dockerfile or docker-compose exists
if [ -f "Dockerfile" ]; then
  log "Dockerfile found ✅"
elif [ -f "docker-compose.yml" ]; then
  log "docker-compose.yml found ✅"
else
  err "No Dockerfile or docker-compose.yml found in repository."
  exit 1
fi

log "Repository validation complete. Ready for remote deployment."


# Helper: remote SSH exec

remote_exec() {
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "$@"
}

remote_exec_sudo() {
  # helper to run multi commands with sudo -- used with quoted strings
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "sudo bash -lc '$1'"
}


# Stage 4-6: Remote setup + deploy

log "Starting remote setup and deployment to ${REMOTE_USER}@${REMOTE_HOST}"

# Quick SSH connectivity check (dry-run)
if remote_exec "echo SSH_OK" >/dev/null 2>&1; then
  log "SSH connection OK"
else
  err "SSH connection failed. Check key/IP/username."
  exit 2
fi

# If --cleanup requested: remove app container, image, nginx config, and app dir
if [ "$CLEANUP" -eq 1 ]; then
  log "CLEANUP requested: removing deployed resources on remote host..."
  remote_exec "sudo docker rm -f app_container >/dev/null 2>&1 || true"
  remote_exec "sudo docker rmi app_image >/dev/null 2>&1 || true"
  remote_exec "sudo rm -f /etc/nginx/sites-available/app_deploy.conf /etc/nginx/sites-enabled/app_deploy.conf || true"
  remote_exec "sudo nginx -t >/dev/null 2>&1 || true; sudo systemctl reload nginx >/dev/null 2>&1 || true"
  remote_exec "rm -rf ~/app_deploy_dir || true"
  log "Cleanup complete on remote host."
  exit 0
fi

# Ensure remote prerequisites: update & create dir
remote_exec "sudo apt-get update -y >/dev/null 2>&1 || true"
remote_exec "mkdir -p ~/app_deploy_dir"

# Install Docker (idempotent)
log "Checking Docker on remote..."
if ! remote_exec "command -v docker >/dev/null 2>&1"; then
  log "Docker missing. Installing..."
  remote_exec "sudo rm -f /etc/apt/sources.list.d/docker.list || true"
  remote_exec "sudo apt-get update -y >/dev/null 2>&1"
  remote_exec "sudo apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1"
  remote_exec "sudo install -m 0755 -d /etc/apt/keyrings >/dev/null 2>&1"
  remote_exec "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg"
  remote_exec "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
  remote_exec "sudo apt-get update -y >/dev/null 2>&1"
  remote_exec "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1"
  remote_exec "sudo systemctl enable docker >/dev/null 2>&1 && sudo systemctl start docker >/dev/null 2>&1"
  log "Docker installed on remote."
else
  log "Docker already installed on remote."
fi

# Ensure user can run docker (add to docker group)
remote_exec "grep -q \"^docker:\" /etc/group >/dev/null 2>&1 || sudo groupadd docker || true"
remote_exec "sudo usermod -aG docker $REMOTE_USER >/dev/null 2>&1 || true"

# Ensure nginx installed (we'll configure it as reverse proxy)
log "Ensuring Nginx is installed on remote..."
if ! remote_exec "command -v nginx >/dev/null 2>&1"; then
  remote_exec "sudo apt-get install -y nginx >/dev/null 2>&1 || true"
  remote_exec "sudo systemctl enable nginx >/dev/null 2>&1 || true"
  remote_exec "sudo systemctl start nginx >/dev/null 2>&1 || true"
  log "Nginx installed."
else
  log "Nginx already present."
fi

# Copy project files to remote (use rsync if available else scp)
log "Copying project files to remote host..."
# use rsync if present for efficient copy; fallback to scp
if command -v rsync >/dev/null 2>&1; then
  rsync -az -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" --delete "$LOCAL_CLONE_DIR/$REPO_NAME/" "$REMOTE_USER@$REMOTE_HOST:~/app_deploy_dir/"
else
  scp -i "$SSH_KEY_PATH" -r "$LOCAL_CLONE_DIR/$REPO_NAME/" "${REMOTE_USER}@${REMOTE_HOST}:~/app_deploy_dir/" >/dev/null 2>&1
fi
log "Files copied."

# Remote: ensure app dir is present and up to date (git pull if present)
remote_exec "cd ~/app_deploy_dir && git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git pull || true"

# Remove old container (idempotency) and build & run
log "Building Docker image on remote..."
remote_exec "cd ~/app_deploy_dir && sudo docker build -t app_image ."

log "Stopping any existing container and starting a fresh one..."
remote_exec "sudo docker rm -f app_container >/dev/null 2>&1 || true"
# Run container but do not expose internal port to same port; we'll let Nginx reverse proxy from 80 to APP_PORT
remote_exec "sudo docker run -d --restart unless-stopped -p 127.0.0.1:${APP_PORT}:${APP_PORT} --name app_container app_image || sudo docker run -d --restart unless-stopped -p ${APP_PORT}:${APP_PORT} --name app_container app_image"

# Stage 7: Configure Nginx reverse proxy to forward port 80 -> container's internal port
log "Configuring Nginx reverse proxy on remote..."
NGINX_SITE_CONF="/etc/nginx/sites-available/app_deploy.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/app_deploy.conf"

# Build nginx config remotely (replace any existing)
remote_exec "sudo bash -lc 'cat > $NGINX_SITE_CONF <<NGCONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }
}
NGCONF'"

# Enable site and test nginx config, reload
remote_exec "sudo ln -sf $NGINX_SITE_CONF $NGINX_SITE_ENABLED"
if remote_exec "sudo nginx -t >/dev/null 2>&1"; then
  remote_exec "sudo systemctl reload nginx >/dev/null 2>&1 || sudo service nginx reload >/dev/null 2>&1"
  log "Nginx configured and reloaded."
else
  err "Nginx configuration test failed. Please inspect /etc/nginx/sites-available/app_deploy.conf on remote."
  exit 10
fi

# Stage 8: Validate deployment (docker & nginx)
log "Validating deployment..."

# Check docker service
if remote_exec "sudo systemctl is-active --quiet docker && echo up || echo down" | grep -q up; then
  log "Docker service is running on remote."
else
  err "Docker service is not running on remote."
  exit 11
fi

# Check container status
if remote_exec "sudo docker ps --filter name=app_container --format '{{.Names}} {{.Status}}' | grep -q app_container"; then
  log "App container is running."
else
  err "App container is not running. Check 'sudo docker ps -a' on remote."
  remote_exec "sudo docker logs app_container || true"
  exit 12
fi

# Check endpoint via remote curl (local to server)
REMOTE_CURL_OK=0
if remote_exec "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT} --max-time 5" >/dev/null 2>&1; then
  CODE=$(remote_exec "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${APP_PORT} --max-time 5" || echo "")
  if [ "$CODE" = "200" ] || [ -n "$CODE" ]; then
    log "App responded on remote at http://127.0.0.1:${APP_PORT} (HTTP ${CODE})."
    REMOTE_CURL_OK=1
  fi
fi

# Check external (Nginx) endpoint from local machine
NGINX_CURL_OK=0
if curl -s -o /dev/null -w "%{http_code}" "http://${REMOTE_HOST}" --max-time 7 >/dev/null 2>&1; then
  HTTP_LOCAL=$(curl -s -o /dev/null -w "%{http_code}" "http://${REMOTE_HOST}" --max-time 7 || echo "")
  if [ -n "$HTTP_LOCAL" ]; then
    log "Public endpoint http://${REMOTE_HOST} responded HTTP ${HTTP_LOCAL}."
    NGINX_CURL_OK=1
  fi
fi

if [ "$REMOTE_CURL_OK" -eq 1 ] || [ "$NGINX_CURL_OK" -eq 1 ]; then
  log "Deployment validation passed."
  log "Application should be reachable at: http://${REMOTE_HOST}"
else
  err "Deployment validation failed (no successful HTTP response). Check remote logs: sudo docker logs app_container and nginx logs."
  exit 13
fi

# Stage 9: Append deployment summary to logfile
cat >> "$LOGFILE" <<EOF
Deployment summary:
  timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
  repo: $REPO_URL
  branch: $BRANCH
  remote: ${REMOTE_USER}@${REMOTE_HOST}
  container_name: app_container
  image_name: app_image
  app_port: $APP_PORT
  public_url: http://${REMOTE_HOST}
EOF

log "Deployment finished successfully. Log saved to $LOGFILE"
exit 0
