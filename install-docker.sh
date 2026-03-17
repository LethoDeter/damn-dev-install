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
GHCR_OWNER="anthonylevy"

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

# ── Prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
  command -v openssl &>/dev/null || die "openssl is required but not found. Install it and re-run."
  command -v curl    &>/dev/null || die "curl is required but not found. Install it and re-run."
}

# ── docker compose compat ──────────────────────────────────────────────────────

resolve_compose_cmd() {
  if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  else
    die "docker compose not found. Update Docker Desktop to v4+ or install the docker-compose plugin."
  fi
}

# ── Docker ────────────────────────────────────────────────────────────────────

ensure_docker() {
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    info "Docker is ready."
    resolve_compose_cmd
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
      info "Docker group added. Re-launching installer under new group..."
      exec sg docker -- bash -c "$(curl -fsSL ${INSTALL_BASE_URL}/install-docker.sh)"
    fi
  fi

  if [[ "$OSTYPE" == "darwin"* ]]; then
    open -a Docker 2>/dev/null || true
    info "Waiting for Docker Desktop to start..."
    for i in $(seq 1 60); do
      sleep 2
      if docker info &>/dev/null 2>&1; then
        success "Docker is ready."
        resolve_compose_cmd
        return 0
      fi
      printf "."
    done
    echo ""
    die "Docker didn't start after 120s. Open Docker Desktop manually then re-run this script."
  else
    sudo systemctl start docker && sleep 3
    docker info &>/dev/null 2>&1 || die "Docker failed to start."
    resolve_compose_cmd
  fi
}

# ── Port check ────────────────────────────────────────────────────────────────

check_port() {
  if lsof -iTCP:"${PORT}" -sTCP:LISTEN &>/dev/null 2>&1; then
    die "Port ${PORT} is already in use. Re-run with a different port: PORT=5175 curl ${INSTALL_BASE_URL}/install-docker.sh | bash"
  fi
}

# ── OpenClaw hardened image ───────────────────────────────────────────────────

pull_openclaw_hardened() {
  info "Pulling OpenClaw (hardened, with Docker CLI)..."
  docker pull "ghcr.io/${GHCR_OWNER}/openclaw-hardened:latest"
  docker tag "ghcr.io/${GHCR_OWNER}/openclaw-hardened:latest" openclaw:hardened
  success "openclaw:hardened ready."
}

# ── openclaw.json ─────────────────────────────────────────────────────────────

write_openclaw_config() {
  if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
    info "Preserving existing openclaw.json (your agents and config are intact)."
    return 0
  fi

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
    "webhookUrl": "http://host.docker.internal:3001/webhooks/openclaw",
    "token": "${OPENCLAW_TOKEN}"
  },
  "plugins": {
    "load": { "paths": ["~/openclaw-plugins/damndev"] },
    "entries": {
      "damndev": {
        "enabled": true,
        "config": {
          "webhookUrl": "http://host.docker.internal:3001/webhooks/openclaw",
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

# ── docker-compose.local.yml ──────────────────────────────────────────────────

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
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - damn-dev-net
    restart: unless-stopped

  backend:
    image: ghcr.io/${GHCR_OWNER}/damn-dev-backend:latest
    container_name: damn-dev-backend
    ports:
      - "3001:3001"
    volumes:
      - ${DAMN_DEV_DIR}:/data
    env_file:
      - ${DAMN_DEV_DIR}/.env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - openclaw
    networks:
      - damn-dev-net
    restart: unless-stopped

  frontend:
    image: ghcr.io/${GHCR_OWNER}/damn-dev-frontend:latest
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

# ── .env ──────────────────────────────────────────────────────────────────────

write_env() {
  local better_auth_secret=""
  if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
    better_auth_secret=$(grep '^BETTER_AUTH_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || true)
  fi
  if [[ -z "${better_auth_secret}" ]]; then
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
DAMN_DEV_VERSION_URL=${INSTALL_BASE_URL}/version.json
ENV_EOF
}

# ── Start ─────────────────────────────────────────────────────────────────────

start_containers() {
  info "Pulling latest damn.dev images..."
  $COMPOSE_CMD -f "$DAMN_DEV_DIR/docker-compose.local.yml" pull backend frontend openclaw

  info "Starting containers..."
  $COMPOSE_CMD -f "$DAMN_DEV_DIR/docker-compose.local.yml" up -d

  info "Waiting for backend..."
  for i in $(seq 1 20); do
    sleep 3
    if curl -sf "http://localhost:3001/health" > /dev/null 2>&1; then
      break
    fi
    printf "."
  done
  echo ""

  info "Waiting for frontend..."
  for i in $(seq 1 20); do
    sleep 3
    if curl -sf "http://localhost:${PORT}" > /dev/null 2>&1; then
      return 0
    fi
    printf "."
  done
  echo ""
  die "damn.dev did not become ready. Check logs: $COMPOSE_CMD -f $DAMN_DEV_DIR/docker-compose.local.yml logs -f"
}

# ── Summary ───────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "damn.dev is running"
  echo "  http://localhost:${PORT}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  To update:  curl ${INSTALL_BASE_URL}/install-docker.sh | bash"
  echo "  To stop:    $COMPOSE_CMD -f $DAMN_DEV_DIR/docker-compose.local.yml down"
  echo "  Logs:       $COMPOSE_CMD -f $DAMN_DEV_DIR/docker-compose.local.yml logs -f"
  echo ""
  echo "  Note: /var/run/docker.sock is mounted into the OpenClaw container to enable"
  echo "  agent sandboxing. This grants the container access to the host Docker daemon."
  echo "  See docs/INSTALL.md for the security implications."
  echo ""
  command -v open     &>/dev/null && open     "http://localhost:${PORT}" 2>/dev/null || true
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_prerequisites

if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
  OPENCLAW_TOKEN=$(grep '^OPENCLAW_TOKEN=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || true)
fi
if [[ -z "${OPENCLAW_TOKEN:-}" ]]; then
  OPENCLAW_TOKEN=$(openssl rand -hex 32)
fi

if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
  DAMNDEV_OUTBOUND_SECRET=$(grep '^DAMNDEV_OUTBOUND_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || true)
fi
if [[ -z "${DAMNDEV_OUTBOUND_SECRET:-}" ]]; then
  DAMNDEV_OUTBOUND_SECRET=$(openssl rand -hex 32)
fi

HOST_UID=$(id -u)
HOST_GID=$(id -g)

ensure_docker
check_port
pull_openclaw_hardened
write_openclaw_config
write_compose
write_env
start_containers
print_summary
