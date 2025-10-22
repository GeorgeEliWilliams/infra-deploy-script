#!/usr/bin/env bash
# deploy.sh - Stage 1: collect and validate user input
# Run: ./deploy.sh
# This section collects parameters required for deployment and validates them.

set -o errexit   # exit on error
set -o nounset   # treat unset variables as error
set -o pipefail  # propagate failures through pipes

# Simple logger functions
log()  { printf "[%s] INFO: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
err()  { printf "[%s] ERROR: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

###########################
# Helper validation funcs #
###########################

# Validate repository URL 
is_valid_repo_url() {
  local url="$1"
  # Accept common forms: https://...git, https://github.com/user/repo, git@github.com:user/repo.git, ssh://...
  if [[ "$url" =~ ^(https://|http://|git@|ssh://) ]]; then
    return 0
  fi
  return 1
}

# Validate integer port (1-65535)
is_valid_port() {
  local p="$1"
  if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
    return 0
  fi
  return 1
}

# Expand ~ to $HOME and remove surrounding quotes/spaces
expand_path() {
  local p="$1"
  # trim whitespace
  p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # expand ~
  if [[ "$p" == "~"* ]]; then
    p="${p/#\~/$HOME}"
  fi
  printf '%s' "$p"
}

###########################
# Prompt / Read functions #
###########################

prompt() {
  local varname="$1"
  local prompt_text="$2"
  local default="${3-}"
  local input
  if [ -n "$default" ]; then
    read -r -p "$prompt_text [$default]: " input
    input="${input:-$default}"
  else
    read -r -p "$prompt_text: " input
  fi
  # assign by name
  printf -v "$varname" "%s" "$input"
}

prompt_secret() {
  # read hidden (PAT)
  local varname="$1"
  local prompt_text="$2"
  local input
  stty -echo
  read -r -p "$prompt_text: " input || true
  stty echo
  printf "\n"
  printf -v "$varname" "%s" "$input"
}

###########################
# Start: Collecting input #
###########################

log "Collecting deployment parameters."

# 1) Repo URL
while true; do
  prompt REPO_URL "Git repository URL (HTTPS or SSH)"
  if [ -z "${REPO_URL// /}" ]; then
    err "Repository URL cannot be empty."
    continue
  fi
  if is_valid_repo_url "$REPO_URL"; then
    break
  else
    err "Repository URL looks invalid. Start with https:// or git@ or ssh://"
  fi
done

# 2) Personal Access Token (PAT) - optional for SSH repos
prompt_secret PAT "Personal Access Token (PAT) for HTTPS repo (leave empty to use SSH/agent if repo uses SSH)"
# (Do not log the PAT)

# 3) Branch (default main)
prompt BRANCH "Branch name" "main"
BRANCH="${BRANCH:-main}"

# 4) Remote SSH username
while true; do
  prompt REMOTE_USER "Remote SSH username (e.g. ubuntu)"
  if [ -n "${REMOTE_USER// /}" ]; then break; else err "Username required."; fi
done

# 5) Remote server IP
while true; do
  prompt REMOTE_HOST "Remote server IP or hostname"
  if [ -n "${REMOTE_HOST// /}" ]; then break; else err "Host/IP required."; fi
done

# 6) SSH key path
while true; do
  prompt SSH_KEY_PATH "Path to SSH private key for remote connection (e.g. ~/Downloads/ec2-key.pem)"
  SSH_KEY_PATH="$(expand_path "$SSH_KEY_PATH")"
  if [ -f "$SSH_KEY_PATH" ]; then
    # ensure the key permissions are strict enough (informative only)
    perm=$(stat -c '%a' "$SSH_KEY_PATH" 2>/dev/null || stat -f '%Lp' "$SSH_KEY_PATH" 2>/dev/null || echo "")
    log "Found SSH key at $SSH_KEY_PATH (permissions: ${perm:-unknown})."
    break
  else
    err "SSH key not found at '$SSH_KEY_PATH'. Please provide a correct path."
  fi
done

# 7) Application internal port
while true; do
  prompt APP_PORT "Application internal container port (e.g. 5000)"
  if is_valid_port "$APP_PORT"; then break; else err "Invalid port. Enter a number between 1 and 65535."; fi
done

# Optional: Ask for a local working directory to clone into (defaults to current directory)
prompt LOCAL_CLONE_DIR "Local directory to clone into (will create if missing)" "."
LOCAL_CLONE_DIR="$(expand_path "$LOCAL_CLONE_DIR")"
mkdir -p "$LOCAL_CLONE_DIR"

# Final confirmation (do not show PAT)
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

# REPO_URL, PAT, BRANCH, REMOTE_USER, REMOTE_HOST, SSH_KEY_PATH, APP_PORT, LOCAL_CLONE_DIR

log "user input collected and validated."

#####################################
# Clone or Update the Repo #
#####################################

log "Cloning repository."

cd "$LOCAL_CLONE_DIR"

# Extract repo name from URL (remove .git if present)
REPO_NAME=$(basename "$REPO_URL" .git)

# If directory already exists, pull latest changes instead
if [ -d "$REPO_NAME/.git" ]; then
  log "Repository '$REPO_NAME' already exists. Pulling latest changes..."
  cd "$REPO_NAME"

  # Ensure we’re on the right branch
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "")
  if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    log "Switching branch from $CURRENT_BRANCH to $BRANCH."
    git fetch origin "$BRANCH" || err "Failed to fetch branch $BRANCH."
    git checkout "$BRANCH" || err "Failed to switch to branch $BRANCH."
  fi

  # Pull latest updates
  git pull origin "$BRANCH" || {
    err "Failed to pull latest changes. Check your access or network."
    exit 1
  }

else
  # Clone new repository
  log "Cloning new repository: $REPO_URL"
  if [[ "$REPO_URL" =~ ^https:// ]]; then
    # HTTPS clone using PAT if provided
    if [ -n "$PAT" ]; then
      # Inject PAT safely (not visible in process list)
      AUTH_URL=$(echo "$REPO_URL" | sed -E "s#https://#https://${PAT}@#")
      git clone --branch "$BRANCH" "$AUTH_URL" || {
        err "Failed to clone repo using PAT."
        exit 1
      }
    else
      git clone --branch "$BRANCH" "$REPO_URL" || {
        err "Failed to clone HTTPS repo (missing PAT?)."
        exit 1
      }
    fi
  else
    # SSH clone (uses ssh-agent / key)
    git clone --branch "$BRANCH" "$REPO_URL" || {
      err "Failed to clone SSH repo. Check your SSH key and GitHub access."
      exit 1
    }
  fi

  cd "$REPO_NAME"
fi

# Verify Dockerfile or docker-compose.yml exists
if [ -f "Dockerfile" ]; then
  log "Dockerfile found ✅"
elif [ -f "docker-compose.yml" ]; then
  log "docker-compose.yml found ✅"
else
  err "No Dockerfile or docker-compose.yml found in repository."
  exit 1
fi

log "Repository validation complete. Ready for remote deployment in next stage."

###############################################################################
# Remote setup and deployment
###############################################################################

log "Starting Stage 3: Remote server setup and deployment."

# Function to run remote commands via SSH
remote_exec() {
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "$@"
}

# 1️⃣ Check SSH connection
log "Checking SSH connection to remote server..."
if remote_exec "echo '✅ SSH connection established successfully.'"; then
  log "SSH connection successful."
else
  err "SSH connection failed. Verify IP, username, and key path."
  exit 1
fi

# 2️⃣ Install Docker if missing
log "Checking Docker installation on remote server..."
if ! remote_exec "command -v docker >/dev/null 2>&1"; then
  log "Docker not found. Installing Docker..."

  # Remove malformed docker.list if it exists
  remote_exec "sudo rm -f /etc/apt/sources.list.d/docker.list"

  # Install prerequisites
  remote_exec "sudo apt-get update -y && sudo apt-get install -y ca-certificates curl gnupg lsb-release"

  # Create keyring directory
  remote_exec "sudo install -m 0755 -d /etc/apt/keyrings"

  # Import Docker GPG key non-interactively
  remote_exec "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg"

  # Add Docker repo (ensure remote eval happens)
  remote_exec "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"

  # Install Docker components
  remote_exec "sudo apt-get update -y && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

  # Enable and start Docker
  remote_exec "sudo systemctl enable docker && sudo systemctl start docker"
  log "Docker installed successfully ✅"
else
  log "Docker already installed ✅"
fi

# 3️⃣ Ensure Docker service is running
remote_exec "sudo systemctl enable docker && sudo systemctl start docker"
log "Docker service ensured to be active."

# 4️⃣ Verify Docker Compose
if ! remote_exec "docker compose version >/dev/null 2>&1"; then
  log "Docker Compose plugin not found. Installing standalone Docker Compose..."
  remote_exec "sudo curl -L 'https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)' -o /usr/local/bin/docker-compose"
  remote_exec "sudo chmod +x /usr/local/bin/docker-compose"
  log "Docker Compose installed."
else
  log "Docker Compose already available ✅"
fi

# 5️⃣ Clone or pull latest repo on remote host
APP_DIR="app_deploy_dir"

log "Checking for existing app directory on remote server..."
if remote_exec "[ -d ~/$APP_DIR/.git ]"; then
  log "App directory exists. Pulling latest changes..."
  remote_exec "cd ~/$APP_DIR && git pull"
else
  log "App directory not found. Cloning fresh copy..."
  remote_exec "git clone -b $BRANCH $REPO_URL ~/$APP_DIR"
fi

# 6️⃣ Build and run the container
log "Building and running Docker container on remote server..."
remote_exec "cd ~/$APP_DIR && sudo docker build -t app_image ."
remote_exec "sudo docker rm -f app_container >/dev/null 2>&1 || true"
remote_exec "sudo docker run -d -p 80:$APP_PORT --name app_container app_image"

log "Application deployed successfully and running on port 80!"
log "You can visit http://$REMOTE_HOST to verify."
