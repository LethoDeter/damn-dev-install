#!/usr/bin/env bash
# damn.dev installer — docker-local pattern:
#   - damn.dev backend runs NATIVELY via @damn-dev/cli (Node 18+)
#   - OpenClaw runs in a Docker container (openclaw:hardened)
#
# Previous versions of this script fully containerized both backend and
# frontend — that's archived as install-docker.sh.deprecated-fullcontainer.
# See PRD.md "Install Paths" for the rationale.

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
PORT="${PORT:-3001}"
DOMAIN=""
INSTALL_BASE_URL="https://raw.githubusercontent.com/LethoDeter/damn-dev-install/main"
GHCR_OWNER="lethodeter"

mkdir -p "$DAMN_DEV_DIR" "$OPENCLAW_DIR"

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port)   PORT="$2";   shift 2 ;;
    *) shift ;;
  esac
done

echo ""
echo -e "${BOLD}damn.dev — Docker-local installer${RESET}"
echo "──────────────────────────────────────"
echo ""

# ── Old fully-containerized install detection ────────────────────────────────
# If we see the old damn-dev-backend or damn-dev-frontend containers, guide the
# user through teardown first. Their data at ~/.damn-dev and ~/.openclaw stays
# intact — only the old containers + compose file need to go.

detect_old_fullcontainer_install() {
  local found=""
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^(damn-dev-backend|damn-dev-frontend)$'; then
    found="yes"
  fi
  if [[ -z "$found" ]]; then return 0; fi

  echo -e "${BOLD}Previous fully-containerized damn.dev setup detected.${RESET}"
  echo ""
  echo "This installer now uses the docker-local pattern:"
  echo "  - damn.dev backend runs NATIVELY (better Ollama/host access)"
  echo "  - Only OpenClaw stays in a Docker container"
  echo ""
  echo "Tear down the old containers first (your data in ~/.damn-dev + ~/.openclaw"
  echo "is preserved — only the backend + frontend containers are removed):"
  echo ""
  echo "  docker compose -f \"$DAMN_DEV_DIR/docker-compose.local.yml\" down"
  echo "  docker rm -f damn-dev-backend damn-dev-frontend 2>/dev/null"
  echo "  rm \"$DAMN_DEV_DIR/docker-compose.local.yml\""
  echo ""
  echo "Then re-run:  curl -fsSL ${INSTALL_BASE_URL}/install-docker.sh | bash"
  echo ""
  exit 0
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
  command -v openssl &>/dev/null || die "openssl is required but not found. Install it and re-run."
  command -v curl    &>/dev/null || die "curl is required but not found. Install it and re-run."
  ensure_node_22
}

# Require Node 22+ because better-auth (and other modern deps) are ESM-only;
# CommonJS require() of ESM is only supported unflagged on Node 22+.
#
# Tiered upgrade flow:
#   1. Node >= 22 already → continue
#   2. No Node OR Node < 22, Homebrew present → offer brew install node@22 (Y/n)
#   3. No brew → point at damn.dev DMG desktop app (bundles own Node, zero setup)
#      + fallback: nodejs.org .pkg installer
ensure_node_22() {
  if command -v node &>/dev/null && \
     node -e "process.exit(parseInt(process.version.slice(1)) < 22 ? 1 : 0)" 2>/dev/null; then
    info "Node.js $(node --version) detected."
    return 0
  fi

  local current
  current=$(command -v node &>/dev/null && node --version 2>/dev/null || echo "(not installed)")
  echo ""
  info "Node.js 22+ is required — damn.dev depends on ESM modules only supported on Node 22+."
  info "Currently: $current"
  echo ""

  # Homebrew path — auto-upgrade with consent
  if command -v brew &>/dev/null; then
    local reply=""
    if [[ -t 0 ]]; then
      read -r -p "Install and activate Node 22 via Homebrew now? [Y/n] " reply </dev/tty
    elif [[ -r /dev/tty ]]; then
      read -r -p "Install and activate Node 22 via Homebrew now? [Y/n] " reply </dev/tty
    else
      reply="Y"  # non-interactive (CI) — proceed
    fi
    reply="${reply:-Y}"
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      info "Installing node@22 via Homebrew..."
      brew install node@22 || die "brew install node@22 failed. Upgrade manually then re-run."
      info "Activating node@22 as the default node..."
      brew link --overwrite --force node@22 || die "brew link failed. Run manually: brew link --overwrite --force node@22"
      # Explicit PATH prepend: `hash -r` only refreshes the shell's command hash
      # table, not $PATH resolution. When this script runs via `curl ... | bash`,
      # the outer bash has a stale PATH that doesn't include Homebrew's node@22
      # keg. Without this, later `npm install` calls either use a different Node
      # or silently exit, leaving the user at a prompt with Node 22 installed
      # but damn.dev NOT installed — requiring manual re-run. Fix added 0.9.16.
      export PATH="$(brew --prefix node@22)/bin:$PATH"
      hash -r
      if node -e "process.exit(parseInt(process.version.slice(1)) < 22 ? 1 : 0)" 2>/dev/null; then
        success "Node $(node --version) is now active — continuing with damn.dev install."
        return 0
      fi
      die "Node was installed but $(node --version) is still the default. Open a new terminal and re-run: curl -fsSL ${INSTALL_BASE_URL:-https://install.damn.dev}/docker | bash"
    fi
    die "Upgrade declined. Install Node 22+ and re-run. Tip: brew install node@22 && brew link --overwrite --force node@22"
  fi

  # No Homebrew — offer two paths
  echo -e "${BOLD}Homebrew not found.${RESET} Two options:"
  echo ""
  echo -e "${BOLD}1. Download the damn.dev desktop app${RESET} (recommended if you don't want to deal with Node):"
  echo "   It bundles its own Node 22 — zero setup. Drag, drop, run."
  echo "   → https://damn.dev  (download section)"
  echo "   → https://github.com/LethoDeter/damn-dev-install/releases/latest  (direct binaries)"
  echo ""
  echo -e "${BOLD}2. Install Node 22 LTS yourself${RESET} (then use the CLI install):"
  echo "   → https://nodejs.org/en/download  (select the macOS .pkg installer)"
  echo "   After install, open a new terminal and re-run:"
  echo "     curl -fsSL ${INSTALL_BASE_URL}/install-docker.sh | bash"
  echo ""
  command -v open     &>/dev/null && open     "https://damn.dev" 2>/dev/null || true
  command -v xdg-open &>/dev/null && xdg-open "https://damn.dev" 2>/dev/null || true
  die "Pick one of the above to continue."
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

# Stop any damn-dev backend we previously started (update flow: user re-runs
# the installer while the backend is still holding :PORT). The CLI's own
# stop command is idempotent and safe on fresh installs where no binary
# exists yet.
pre_stop_existing_damndev() {
  command -v damn-dev &>/dev/null && damn-dev stop >/dev/null 2>&1 || true
}

check_port() {
  if lsof -iTCP:"${PORT}" -sTCP:LISTEN &>/dev/null 2>&1; then
    die "Port ${PORT} is already in use by another process. Re-run with a different port: PORT=3002 curl ${INSTALL_BASE_URL}/install-docker.sh | bash"
  fi
}

# Catch the npm-path → docker-local migration: user previously ran
# install.damn.dev/npm (native OpenClaw on :18789). Our Docker OpenClaw
# would collide on :18789. Detect before `docker compose up` fails opaquely.
detect_native_openclaw_conflict() {
  lsof -iTCP:18789 -sTCP:LISTEN &>/dev/null 2>&1 || return 0

  # Is the listener a Docker container (com.docker.vpnkit proxy) or a native process?
  local pid
  pid=$(lsof -iTCP:18789 -sTCP:LISTEN -t 2>/dev/null | head -1)
  if [[ -z "$pid" ]]; then return 0; fi

  local comm
  comm=$(ps -p "$pid" -o comm= 2>/dev/null)
  # Docker's port publisher appears as 'com.docker.backend' / 'vpnkit' / 'Docker Desktop'.
  # Anything else on :18789 is a native OpenClaw process.
  if echo "$comm" | grep -qiE 'docker|vpnkit'; then
    return 0
  fi

  echo -e "${BOLD}Native OpenClaw detected on :18789.${RESET}"
  echo ""
  echo "This installer uses Docker OpenClaw, which also needs :18789."
  echo "Stop the native OpenClaw first:"
  echo ""
  if [[ -f "$DAMN_DEV_DIR/openclaw.pid" ]]; then
    echo "  pkill -F \"$DAMN_DEV_DIR/openclaw.pid\""
  else
    echo "  pkill -f openclaw"
  fi
  echo ""
  echo "Then re-run:  curl -fsSL ${INSTALL_BASE_URL}/install-docker.sh | bash"
  echo ""
  exit 0
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
    "auth": { "token": "${OPENCLAW_TOKEN}" },
    "bind": "lan",
    "mode": "local",
    "controlUi": {
      "allowedOrigins": ["http://localhost:18789", "http://127.0.0.1:18789"]
    }
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
        "mode": "off"
      }
    },
    "list": []
  },
  "hooks": {
    "allowedAgentIds": [],
    "token": "${OPENCLAW_TOKEN}"
  },
  "plugins": {
    "load": { "paths": ["~/openclaw-plugins/damndev"] },
    "entries": {
      "damndev": {
        "enabled": true,
        "config": {
          "webhookUrl": "http://host.docker.internal:${PORT}/webhooks/openclaw",
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
      # Mount host's ~/openclaw-plugins over the image-baked copy. Required
      # because openclaw:hardened bakes the plugin at uid=1000 (image build
      # user), but the container runs as \${HOST_UID} (e.g. 501 on macOS) via
      # the 'user' directive above. OpenClaw's plugin loader rejects
      # "suspicious ownership" (owner != running user && owner != root). The
      # install script cp's the plugin into ~/openclaw-plugins during install,
      # so the host dir is owned by the host user — ownership check passes.
      - ${HOME}/openclaw-plugins:/home/node/openclaw-plugins:ro
    environment:
      - OPENCLAW_GATEWAY_BIND=lan
    env_file:
      - ${OPENCLAW_DIR}/.env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped
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
DATABASE_URL=file:${DAMN_DEV_DIR}/damn.db
OPENCLAW_URL=http://localhost:18789
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
BETTER_AUTH_SECRET=${better_auth_secret}
DOMAIN=${DOMAIN}
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET}
DAMNDEV_INSTALL_PATH=docker-local
ENV_EOF
}

# ── Ensure ~/.openclaw/.env exists for the compose env_file mount ─────────────

ensure_openclaw_env() {
  [[ -f "$OPENCLAW_DIR/.env" ]] || touch "$OPENCLAW_DIR/.env"
}

# ── Install @damn-dev/cli ────────────────────────────────────────────────────

install_damn_dev() {
  if ! npm list -g @damn-dev/cli --depth=0 &>/dev/null; then
    info "Installing @damn-dev/cli..."
    npm install -g @damn-dev/cli
  else
    info "@damn-dev/cli already installed — checking for updates..."
    npm install -g @damn-dev/cli
  fi

  # The damndev OpenClaw plugin ships inside the @damn-dev/cli package.
  local plugin_src
  plugin_src="$(npm root -g)/@damn-dev/cli/runtime/plugins/damndev"
  if [[ ! -d "$plugin_src" ]]; then
    die "damndev plugin not found at $plugin_src — the @damn-dev/cli install is broken."
  fi
  mkdir -p ~/openclaw-plugins
  rm -rf ~/openclaw-plugins/damndev
  cp -r "$plugin_src" ~/openclaw-plugins/damndev
}

# ── Start OpenClaw container ─────────────────────────────────────────────────

start_openclaw() {
  info "Starting OpenClaw container..."
  $COMPOSE_CMD -f "$DAMN_DEV_DIR/docker-compose.local.yml" up -d

  # OpenClaw's first startup (fresh container, loads config, resolves auth,
  # starts HTTP server, registers plugins) takes 30-60s on Apple Silicon and
  # can exceed 60s on Intel Macs. Wait up to 90s before giving up. Observed
  # real-world: 25s on M-series, 35-45s on Intel.
  info "Waiting for OpenClaw..."
  for i in $(seq 1 45); do
    sleep 2
    if curl -sf http://localhost:18789/health > /dev/null 2>&1; then
      success "OpenClaw is running."
      return 0
    fi
    printf "."
  done
  echo ""
  die "OpenClaw did not become healthy within 90s. Check logs: $COMPOSE_CMD -f $DAMN_DEV_DIR/docker-compose.local.yml logs -f"
}

# ── Start damn-dev backend ───────────────────────────────────────────────────

start_damn_dev() {
  # @damn-dev/cli manages its own pidfile at ~/.damn-dev/damn-dev.pid.
  damn-dev stop >/dev/null 2>&1 || true
  damn-dev start --port "$PORT"

  info "Waiting for damn.dev to start..."
  for i in $(seq 1 15); do
    sleep 2
    if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
      success "damn.dev is ready."
      return 0
    fi
    printf "."
  done
  echo ""
  die "damn.dev did not start in time. Check logs: $DAMN_DEV_DIR/damn-dev.log"
}

# ── Summary ───────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "damn.dev is running"
  echo "  http://localhost:${PORT}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Backend:  damn-dev (native, port ${PORT})"
  echo "  OpenClaw: Docker container (openclaw:hardened)"
  echo ""
  echo "  To update:  curl -fsSL install.damn.dev/docker | bash"
  echo "  To stop:    damn-dev stop && $COMPOSE_CMD -f $DAMN_DEV_DIR/docker-compose.local.yml down"
  echo "  Logs:       $COMPOSE_CMD -f $DAMN_DEV_DIR/docker-compose.local.yml logs -f"
  echo ""
  echo "  Note: /var/run/docker.sock is mounted into the OpenClaw container to enable"
  echo "  agent sandboxing. This grants the container access to the host Docker daemon."
  echo ""
  command -v open     &>/dev/null && open     "http://localhost:${PORT}" 2>/dev/null || true
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" 2>/dev/null || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

check_prerequisites
ensure_docker
detect_old_fullcontainer_install
detect_native_openclaw_conflict
pre_stop_existing_damndev
check_port

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

pull_openclaw_hardened
write_openclaw_config
write_compose
write_env
ensure_openclaw_env
install_damn_dev
start_openclaw
start_damn_dev
print_summary
