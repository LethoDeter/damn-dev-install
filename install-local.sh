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
echo -e "${BOLD}damn.dev — npm installer${RESET}"
echo "──────────────────────────────────"
echo ""

check_node() {
  if ! command -v node &>/dev/null; then
    die "Node.js is required. Install it from https://nodejs.org (LTS version) then re-run this script."
  fi
  if ! node -e "process.exit(parseInt(process.version.slice(1)) < 18 ? 1 : 0)" 2>/dev/null; then
    die "Node.js 18+ required. Current version: $(node --version)"
  fi
  info "Node.js $(node --version) detected."
}

install_openclaw() {
  if [[ -f "$DAMN_DEV_DIR/openclaw.pid" ]] && kill -0 "$(cat "$DAMN_DEV_DIR/openclaw.pid")" 2>/dev/null; then
    if curl -sf http://localhost:18789/health > /dev/null 2>&1; then
      info "OpenClaw already running — skipping."
      OPENCLAW_TOKEN=$(grep -m1 '"token"' "$OPENCLAW_DIR/openclaw.json" 2>/dev/null | sed 's/.*"token": *"\([^"]*\)".*/\1/' || openssl rand -hex 32)
      return 0
    fi
  fi

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

  if ! npm list -g openclaw --depth=0 &>/dev/null; then
    info "Installing OpenClaw..."
    npm install -g openclaw
  else
    info "OpenClaw already installed globally."
  fi

  PLUGIN_SRC="$(npm root -g)/damn-dev/openclaw-plugins/damndev"
  if [[ -d "$PLUGIN_SRC" ]]; then
    mkdir -p ~/openclaw-plugins
    cp -r "$PLUGIN_SRC" ~/openclaw-plugins/damndev
  fi

  cat > "$OPENCLAW_DIR/openclaw.json" << OPENCLAW_EOF
{
  "gateway": {
    "auth": { "token": "${OPENCLAW_TOKEN}" },
    "bind": "loopback",
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
        "mode": "non-main"
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
          "webhookUrl": "http://localhost:3001/webhooks/openclaw",
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

  info "Starting OpenClaw..."
  nohup openclaw start > "$DAMN_DEV_DIR/openclaw.log" 2>&1 &
  echo $! > "$DAMN_DEV_DIR/openclaw.pid"

  for i in $(seq 1 15); do
    sleep 2
    if curl -sf http://localhost:18789/health > /dev/null 2>&1; then
      success "OpenClaw is running."
      return 0
    fi
    printf "."
  done
  echo ""
  die "OpenClaw did not start. Check $DAMN_DEV_DIR/openclaw.log"
}

install_damn_dev() {
  if ! npm list -g damn-dev --depth=0 &>/dev/null; then
    info "Installing damn.dev..."
    npm install -g damn-dev
  else
    info "damn.dev already installed — checking for updates..."
    npm install -g damn-dev
  fi

  local better_auth_secret
  if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
    better_auth_secret=$(grep '^BETTER_AUTH_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
  fi
  if [[ -z "${better_auth_secret:-}" ]]; then
    better_auth_secret=$(openssl rand -hex 32)
  fi

  cat > "$DAMN_DEV_DIR/.env" << ENV_EOF
DATABASE_URL=file:${DAMN_DEV_DIR}/damn.db
OPENCLAW_URL=http://localhost:18789
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
BETTER_AUTH_SECRET=${better_auth_secret}
DOMAIN=${DOMAIN}
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET}
DAMN_DEV_VERSION_URL=https://raw.githubusercontent.com/LethoDeter/damn-dev-install/main/version.json
ENV_EOF

  if [[ -f "$DAMN_DEV_DIR/damn-dev.pid" ]] && kill -0 "$(cat "$DAMN_DEV_DIR/damn-dev.pid")" 2>/dev/null; then
    info "damn.dev already running — restarting..."
    kill "$(cat "$DAMN_DEV_DIR/damn-dev.pid")" 2>/dev/null || true
    sleep 2
  fi

  damn-dev start --port "$PORT" &
  echo $! > "$DAMN_DEV_DIR/damn-dev.pid"

  info "Waiting for damn.dev to start..."
  for i in $(seq 1 15); do
    sleep 2
    if curl -sf "http://localhost:${PORT}/api/health" > /dev/null 2>&1; then
      return 0
    fi
    printf "."
  done
  echo ""
  die "damn.dev did not start in time. Check logs."
}

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "damn.dev is running"
  echo "  http://localhost:${PORT}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  To update:  curl ${INSTALL_BASE_URL}/install-local.sh | bash"
  echo "  To stop:    pkill -F $DAMN_DEV_DIR/damn-dev.pid && pkill -F $DAMN_DEV_DIR/openclaw.pid"
  echo ""
  command -v open    &>/dev/null && open    "http://localhost:${PORT}" || true
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" 2>/dev/null || true
}

check_node
install_openclaw
install_damn_dev
print_summary
