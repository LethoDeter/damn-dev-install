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
PORT="${PORT:-3001}"
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

# ── Node.js prerequisite ──────────────────────────────────────────────────────

check_node() {
  if ! command -v node &>/dev/null; then
    die "Node.js is required. Install it from https://nodejs.org (LTS version) then re-run this script."
  fi
  if ! node -e "process.exit(parseInt(process.version.slice(1)) < 18 ? 1 : 0)" 2>/dev/null; then
    die "Node.js 18+ required. Current version: $(node --version)"
  fi
  info "Node.js $(node --version) detected."
}

# ── npm package installation (CLI first so plugin is available for OpenClaw) ──

install_npm_packages() {
  if ! npm list -g @damn-dev/cli --depth=0 &>/dev/null; then
    info "Installing @damn-dev/cli..."
    npm install -g @damn-dev/cli
  else
    info "@damn-dev/cli already installed — checking for updates..."
    npm install -g @damn-dev/cli
  fi

  if ! npm list -g openclaw --depth=0 &>/dev/null; then
    info "Installing OpenClaw..."
    npm install -g openclaw
  else
    info "OpenClaw already installed."
  fi
}

# ── Secret hydration (reuse across re-installs) ───────────────────────────────

hydrate_secrets() {
  if [[ -f "$DAMN_DEV_DIR/.env" ]]; then
    OPENCLAW_TOKEN=$(grep '^OPENCLAW_TOKEN=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
    DAMNDEV_OUTBOUND_SECRET=$(grep '^DAMNDEV_OUTBOUND_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
    BETTER_AUTH_SECRET=$(grep '^BETTER_AUTH_SECRET=' "$DAMN_DEV_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "")
  fi
  [[ -z "${OPENCLAW_TOKEN:-}" ]]          && OPENCLAW_TOKEN=$(openssl rand -hex 32)
  [[ -z "${DAMNDEV_OUTBOUND_SECRET:-}" ]] && DAMNDEV_OUTBOUND_SECRET=$(openssl rand -hex 32)
  [[ -z "${BETTER_AUTH_SECRET:-}" ]]      && BETTER_AUTH_SECRET=$(openssl rand -hex 32)
}

# ── OpenClaw configure + start ────────────────────────────────────────────────

configure_openclaw() {
  # Copy bundled damndev plugin from the @damn-dev/cli package (installed above).
  local plugin_src
  plugin_src="$(npm root -g)/@damn-dev/cli/runtime/plugins/damndev"
  if [[ ! -d "$plugin_src" ]]; then
    die "damndev plugin not found at $plugin_src — the @damn-dev/cli install is broken."
  fi
  mkdir -p ~/openclaw-plugins
  rm -rf ~/openclaw-plugins/damndev
  cp -r "$plugin_src" ~/openclaw-plugins/damndev

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
      "sandbox": { "mode": "non-main" }
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
          "webhookUrl": "http://localhost:${PORT}/webhooks/openclaw",
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

start_openclaw() {
  if [[ -f "$DAMN_DEV_DIR/openclaw.pid" ]] && kill -0 "$(cat "$DAMN_DEV_DIR/openclaw.pid")" 2>/dev/null; then
    if curl -sf http://localhost:18789/health > /dev/null 2>&1; then
      info "OpenClaw already running — reloading config via restart..."
      kill "$(cat "$DAMN_DEV_DIR/openclaw.pid")" 2>/dev/null || true
      sleep 2
    fi
  fi

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

# ── damn.dev configure + start ────────────────────────────────────────────────

configure_damn_dev() {
  cat > "$DAMN_DEV_DIR/.env" << ENV_EOF
DATABASE_URL=file:${DAMN_DEV_DIR}/damn.db
OPENCLAW_URL=http://localhost:18789
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
DOMAIN=${DOMAIN}
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET}
ENV_EOF
}

start_damn_dev() {
  # damn-dev CLI manages its own pidfile (writes to ~/.damn-dev/damn-dev.pid).
  # Re-running start when already up is refused by the CLI, so stop first.
  damn-dev stop >/dev/null 2>&1 || true
  damn-dev start --port "$PORT"

  info "Waiting for damn.dev to start..."
  for i in $(seq 1 15); do
    sleep 2
    if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
      return 0
    fi
    printf "."
  done
  echo ""
  die "damn.dev did not start in time. Check $DAMN_DEV_DIR/damn-dev.log"
}

# ── Summary ───────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "damn.dev is running"
  echo "  http://localhost:${PORT}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  To update:  curl -fsSL install.damn.dev/npm | bash"
  echo "  To stop:    damn-dev stop && pkill -F $DAMN_DEV_DIR/openclaw.pid"
  echo ""
  command -v open     &>/dev/null && open     "http://localhost:${PORT}" >/dev/null 2>&1 || true
  command -v xdg-open &>/dev/null && xdg-open "http://localhost:${PORT}" 2>/dev/null     || true
}

# ── Orchestrate ───────────────────────────────────────────────────────────────

check_node
install_npm_packages
hydrate_secrets
configure_openclaw
start_openclaw
configure_damn_dev
start_damn_dev
print_summary
