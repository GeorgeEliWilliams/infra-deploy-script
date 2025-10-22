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

log "Stage 1 complete: user input collected and validated."
