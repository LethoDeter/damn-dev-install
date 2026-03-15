#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BOLD}[damn.dev]${RESET} $*"; }
success() { echo -e "${GREEN}[damn.dev]${RESET} $*"; }
die()     { echo -e "${RED}[damn.dev] ERROR:${RESET} $*" >&2; exit 1; }

DAMN_DEV_DIR="$HOME/.damn-dev"
OPENCLAW_DIR="$HOME/.openclaw"
PORT="${PORT:-5174}"
DOMAIN=""
INSTALL_BASE_URL="https://raw.githubusercontent.com/LethoDeter/damn-dev-install/main"

mkdir -p "$DAMN_DEV_DIR" "$OPENCLAW_DIR"

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port)   PORT="$2";   shift 2 ;;
    *) shift ;;
  esac
done

echo ""
echo -e "${BOLD}damn.dev — Docker installer${RESET}"
echo "──────────────────────────────────"
echo ""

ensure_docker() {
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    info "Docker is ready."
    return 0
  fi

  if ! command -v docker &>/dev/null; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo ""
      echo "Docker Desktop is required."
      echo "Download from: https://www.docker.com/products/docker-desktop/"
      echo ""
      echo "After installing Docker Desktop, press Enter to continue..."
      read -r
    else
      info "Installing Docker..."
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker "$USER"
      newgrp docker
    fi
  fi

  if [[ "$OSTYPE" == "darwin"* ]]; then
    open -a Docker
    info "Starting Docker Desktop..."
    for i in $(seq 1 30); do
      sleep 2
      if docker info &>/dev/null 2>&1; then
        success "Docker is ready."
        return 0
      fi
      printf "."
    done
    echo ""
    die "Docker didn't start. Open Docker Desktop manually then re-run this script."
  else
    sudo systemctl start docker && sleep 3
    docker info &>/dev/null 2>&1 || die "Docker failed to start."
  fi
}

write_openclaw_config() {
  cat > "$OPENCLAW_DIR/openclaw.json" << OPENCLAW_EOF
{
  "gateway": {
    "token": "${OPENCLAW_TOKEN}",
    "bind": "lan",
    "mode": "local"
  },
  "bindings": [
    {
      "agentId": "default",
      "match": { "channel": "damndev", "accountId": "default" }
    }
  ],
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "non-main"
      }
    },
    "list": []
  },
  "hooks": {
    "allowedAgentIds": [],
    "webhookUrl": "http://damn-dev-backend:3001/webhooks/openclaw",
    "token": "${OPENCLAW_TOKEN}"
  },
  "plugins": {
    "load": { "paths": ["~/openclaw-plugins/damndev"] },
    "entries": {
      "damndev": {
        "enabled": true,
        "config": {
          "webhookUrl": "http://damn-dev-backend:3001/webhooks/openclaw",
          "authToken": "${OPENCLAW_TOKEN}",
          "inboundSharedSecret": "${DAMNDEV_OUTBOUND_SECRET}",
          "hookForwardUrl": "http://localhost:18789/hooks/agent",
          "hookToken": "${OPENCLAW_TOKEN}",
          "defaultAgentId": "default",
          "defaultSessionPrefix": "damndev:",
          "defaultName": "User",
          "forwardTimeoutMs": 30000
        }
      }
    }
  }
}
OPENCLAW_EOF
}

build_openclaw_hardened() {
  info "Building OpenClaw with Docker CLI support (required for agent sandboxing)..."
  local build_dir
  build_dir=$(mktemp -d)
  cat > "$build_dir/Dockerfile" << 'DOCKEREOF'
FROM ghcr.io/openclaw/openclaw:latest
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
  && chmod a+r /etc/apt/keyrings/docker.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
USER node
DOCKEREOF
  docker build -t openclaw:hardened "$build_dir" 2>&1 | grep -E '(Step|Successfully|ERROR|error)' || true
  rm -rf "$build_dir"
  success "openclaw:hardened built."
}

write_compose() {
  cat > "$DAMN_DEV_DIR/docker-compose.local.yml" << COMPOSE_EOF
services:
  openclaw:
    image: openclaw:hardened
    container_name: damn-dev-openclaw
    user: "${HOST_UID}:${HOST_GID}"
    ports:
      - "18789:18789"
    volumes:
      - ${OPENCLAW_DIR}:/home/node/.openclaw
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - OPENCLAW_GATEWAY_BIND=lan
    networks:
      - damn-dev-net
    restart: unless-stopped

  backend:
    image: ghcr.io/anthonylevy/damn-dev-backend:latest
    container_name: damn-dev-backend
    ports:
      - "3001:3001"
    volumes:
      - ${DAMN_DEV_DIR}:/data
    env_file:
      - ${DAMN_DEV_DIR}/.env
    depends_on:
      - openclaw
    networks:
      - damn-dev-net
    restart: unless-stopped

  frontend:
    image: ghcr.io/anthonylevy/damn-dev-frontend:latest
    container_name: damn-dev-frontend
    ports:
      - "${PORT}:80"
    depends_on:
      - backend
    networks:
      - damn-dev-net
    restart: unless-stopped

networks:
  damn-dev-net:
    driver: bridge
COMPOSE_EOF
}

write_env() {
  local better_auth_secret
  if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
    better_auth_secret=$(grep '^BETTER_AUTH_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
  fi
  if [[ -z "${better_auth_secret:-}" ]]; then
    better_auth_secret=$(openssl rand -hex 32)
  fi

  cat > "$DAMN_DEV_DIR/.env" << ENV_EOF
PORT=${PORT}
DATABASE_URL=file:/data/damn.db
OPENCLAW_URL=http://openclaw:18789
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
BETTER_AUTH_SECRET=${better_auth_secret}
DOMAIN=${DOMAIN}
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET}
DAMN_DEV_VERSION_URL=https://raw.githubusercontent.com/LethoDeter/damn-dev-install/main/version.json
ENV_EOF
}

start_containers() {
  info "Pulling latest damn.dev images and starting containers..."
  docker compose -f "$DAMN_DEV_DIR/docker-compose.local.yml" pull backend frontend
  docker compose -f "$DAMN_DEV_DIR/docker-compose.local.yml" up -d

  info "Waiting for damn.dev to be ready..."
  for i in $(seq 1 20); do
    sleep 3
    if curl -sf "http://localhost:${PORT}" > /dev/null 2>&1; then
      return 0
    fi
    printf "."
  done
  echo ""
  die "damn.dev did not become ready. Check: docker compose -f $DAMN_DEV_DIR/docker-compose.local.yml logs"
}

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "damn.dev is running"
  echo "  http://localhost:${PORT}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  To update:  curl ${INSTALL_BASE_URL}/install-docker.sh | bash"
  echo "  To stop:    docker compose -f $DAMN_DEV_DIR/docker-compose.local.yml down"
  echo "  Logs:       docker compose -f $DAMN_DEV_DIR/docker-compose.local.yml logs -f"
  echo ""
  echo "  Note: /var/run/docker.sock is mounted into the OpenClaw container to enable"
  echo "  agent sandboxing. This grants the container access to the host Docker daemon."
  echo "  See docs/INSTALL.md for the security implications."
  echo ""
  command -v open     &>/dev/null && open     "http://localhost:${PORT}" || true
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" 2>/dev/null || true
}

if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
  OPENCLAW_TOKEN=$(grep '^OPENCLAW_TOKEN=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
fi
if [[ -z "${OPENCLAW_TOKEN:-}" ]]; then
  OPENCLAW_TOKEN=$(openssl rand -hex 32)
fi

if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
  DAMNDEV_OUTBOUND_SECRET=$(grep '^DAMNDEV_OUTBOUND_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
fi
if [[ -z "${DAMNDEV_OUTBOUND_SECRET:-}" ]]; then
  DAMNDEV_OUTBOUND_SECRET=$(openssl rand -hex 32)
fi

HOST_UID=$(id -u)
HOST_GID=$(id -g)

ensure_docker
build_openclaw_hardened
write_openclaw_config
write_compose
write_env
start_containers
print_summary
