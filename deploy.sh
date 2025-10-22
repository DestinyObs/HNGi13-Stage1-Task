#!/usr/bin/env bash

# HNG DevOps Stage 1 Task — Automated Deployment Script
# Author: Destiny Obueh (refactored)

set -euo pipefail

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Simple logger
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

handle_error() {
    local lineno=${1:-unknown}
    log "Error at line ${lineno}. Exiting."
    exit 1
}

trap 'handle_error $LINENO' ERR INT TERM

# Default flags
CLEANUP=false

if [ "${1:-}" = "--cleanup" ]; then
    CLEANUP=true
fi

# -------------------------------
# 1. Collect Parameters
# -------------------------------
read -r -p "Enter Git repository URL: " GIT_REPO
read -r -p "Enter Personal Access Token (PAT): " PAT
read -r -p "Enter branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}
read -r -p "Enter remote server username: " REMOTE_USER
read -r -p "Enter remote server IP address: " REMOTE_IP
read -r -p "Enter SSH key path: " SSH_KEY
read -r -p "Enter application port (container internal port): " APP_PORT

# Basic validation
if [ -z "$GIT_REPO" ] || [ -z "$PAT" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_IP" ] || [ -z "$SSH_KEY" ] || [ -z "$APP_PORT" ]; then
    log "Missing required parameters. Please provide all values."
    exit 2
fi

if ! printf '%s' "$APP_PORT" | grep -Eq '^[0-9]+$'; then
    log "Application port must be a number."
    exit 3
fi

# -------------------------------
# 2. Clone or Pull Repository
# -------------------------------
REPO_NAME=$(basename -s .git "$GIT_REPO")
SANITIZED_NAME=$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-_')

if [ -d "$REPO_NAME" ]; then
    log "Repository '$REPO_NAME' exists locally — pulling latest changes on branch '$BRANCH'."
    (cd "$REPO_NAME" && git fetch --all && git checkout "$BRANCH" && git pull origin "$BRANCH") | tee -a "$LOG_FILE"
else
    log "Cloning repository..."
    # embed PAT into https URL for cloning
    CLONE_URL="$GIT_REPO"
    if printf '%s' "$GIT_REPO" | grep -q '^https://'; then
        CLONE_URL="https://${PAT}@${GIT_REPO#https://}"
    fi
    git clone "$CLONE_URL" "$REPO_NAME" | tee -a "$LOG_FILE"
    (cd "$REPO_NAME" && git checkout "$BRANCH") | tee -a "$LOG_FILE"
fi

# Ensure we're inside the repo directory moving forward
cd "$REPO_NAME"

# -------------------------------
# 3. Verify Docker Configuration
# -------------------------------
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    log "docker-compose file found. Using docker-compose deployment."
    DEPLOY_TYPE="compose"
elif [ -f "Dockerfile" ]; then
    log "Dockerfile found. Using docker build/run deployment."
    DEPLOY_TYPE="dockerfile"
else
    log "No Dockerfile or docker-compose.yml found in project. Exiting."
    exit 4
fi

# -------------------------------
# 4. Test SSH Connection
# -------------------------------
log "Testing SSH connection to $REMOTE_USER@$REMOTE_IP..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_USER@$REMOTE_IP" 'echo SSH_OK' >/dev/null 2>&1; then
    log "SSH connection failed. Exiting."
    exit 5
fi

# -------------------------------
# 5. Prepare Remote Environment
# -------------------------------
log "Preparing remote server environment..."

ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash -s -- <<-REMOTE
set -e
echo "Updating apt and installing prerequisites if missing..."
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y docker.io
fi
if ! command -v docker-compose >/dev/null 2>&1; then
  sudo apt-get install -y docker-compose
fi
if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get install -y nginx
fi
sudo systemctl enable --now docker || true
sudo systemctl enable --now nginx || true
sudo usermod -aG docker "$REMOTE_USER" || true
docker --version || true
docker-compose --version || true
nginx -v || true
REMOTE

# -------------------------------
# 6. Transfer project files to remote and Deploy
# -------------------------------
log "Transferring project files to remote server (rsync)..."
RSYNC_EXCLUDES=(--exclude ".git" --exclude "$LOG_FILE")
rsync -az --delete "${RSYNC_EXCLUDES[@]}" -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" ./ "$REMOTE_USER@$REMOTE_IP:~/$REPO_NAME/" | tee -a "$LOG_FILE"

log "Deploying application on remote host..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash -s "$REPO_NAME" "$SANITIZED_NAME" "$APP_PORT" <<'REMOTE'
set -e
REPO_NAME="$1"
SANITIZED_NAME="$2"
APP_PORT="$3"
REPO_DIR="$HOME/$REPO_NAME"
cd "$REPO_DIR"
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    echo "Using docker-compose for deployment"
    sudo docker-compose down || true
    sudo docker-compose up -d --build
else
    CONTAINER_NAME="${SANITIZED_NAME}_container"
    IMAGE_NAME="${SANITIZED_NAME}_image"
    sudo docker stop "$CONTAINER_NAME" || true
    sudo docker rm "$CONTAINER_NAME" || true
    sudo docker build -t "$IMAGE_NAME" .
    sudo docker run -d -p $APP_PORT:$APP_PORT --name "$CONTAINER_NAME" --restart unless-stopped "$IMAGE_NAME"
    echo "Container deployed and accessible on port $APP_PORT"
fi
REMOTE

# -------------------------------
# 7. Configure Nginx Reverse Proxy
# -------------------------------
log "Configuring Nginx reverse proxy on remote host..."

NGINX_CONF_PATH="/etc/nginx/sites-available/${SANITIZED_NAME}.conf"
NGINX_LINK_PATH="/etc/nginx/sites-enabled/${SANITIZED_NAME}.conf"

ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash -s "$SANITIZED_NAME" "$APP_PORT" <<'REMOTE'
set -e
SANITIZED_NAME="$1"
APP_PORT="$2"
NGINX_CONF_PATH="/etc/nginx/sites-available/${SANITIZED_NAME}.conf"
NGINX_LINK_PATH="/etc/nginx/sites-enabled/${SANITIZED_NAME}.conf"

sudo bash -c "cat > ${NGINX_CONF_PATH}" <<'NGINX_CONF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:APP_PORT_PLACEHOLDER;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX_CONF

sudo sed -i "s/APP_PORT_PLACEHOLDER/${APP_PORT}/g" "${NGINX_CONF_PATH}"
sudo ln -sf "${NGINX_CONF_PATH}" "${NGINX_LINK_PATH}"
sudo nginx -t
sudo systemctl reload nginx
REMOTE

# -------------------------------
# 8. Validate Deployment
# -------------------------------
log "Validating deployment on remote host..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash -s "$APP_PORT" <<'REMOTE'
set -e
APP_PORT="$1"
echo "Docker service status:"
sudo systemctl is-active --quiet docker && echo "docker: active" || echo "docker: inactive"
echo ""
echo "Running containers:"
sudo docker ps
echo ""
echo "Nginx status:"
sudo systemctl is-active --quiet nginx && echo "nginx: active" || echo "nginx: inactive"
echo ""
if command -v curl >/dev/null 2>&1; then
  echo "Testing container on port ${APP_PORT}:"
  curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:${APP_PORT} || echo "Failed to reach container"
  echo ""
  echo "Testing Nginx proxy on port 80:"
  curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:80 || echo "Failed to reach Nginx proxy"
else
  echo "curl not available; skipping HTTP checks"
fi
REMOTE

log "Deployment completed successfully."

# -------------------------------
# 9. Cleanup Option
# -------------------------------
if [ "$CLEANUP" = true ]; then
  log "Cleanup mode enabled. Removing deployed resources on remote host..."
  ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" bash -s "$REPO_NAME" "$SANITIZED_NAME" <<'REMOTE'
set -e
REPO_NAME="$1"
SANITIZED_NAME="$2"
cd "$HOME/$REPO_NAME" || true
sudo docker-compose down || true
sudo docker stop ${SANITIZED_NAME}_container || true
sudo docker rm ${SANITIZED_NAME}_container || true
sudo rm -rf "$HOME/$REPO_NAME" || true
sudo rm -f "/etc/nginx/sites-available/${SANITIZED_NAME}.conf" || true
sudo rm -f "/etc/nginx/sites-enabled/${SANITIZED_NAME}.conf" || true
sudo systemctl reload nginx || true
REMOTE
  log "Cleanup on remote host finished."
fi

exit 0
