#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BOLD}[damn.dev]${RESET} $*"; }
success() { echo -e "${GREEN}[damn.dev]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[damn.dev]${RESET} $*"; }
die()     { echo -e "${RED}[damn.dev] ERROR:${RESET} $*" >&2; exit 1; }

# ── Root required ────────────────────────────────────────────────────────────
# This installer writes /opt/damn-dev + mounts /root/.openclaw + /root/.damn-dev,
# so it only works when $HOME == /root, i.e. actually root. Running as a sudo user
# (where $HOME may be /home/user) half-runs and splits state. Fail fast before any
# secret gen or mkdir.
if [ "$(id -u)" -ne 0 ]; then
  die "This installer must run as root. Do:  sudo -i   then re-run the curl command."
fi


echo ""
echo -e "${BOLD}damn.dev — self-hosted installer${RESET}"
echo "──────────────────────────────────"
echo ""

# ── Pre-flight checks ───────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
  die "Docker is not installed. Install it from https://docs.docker.com/get-docker/ then re-run this script."
fi

DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+' | head -1)
DOCKER_MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)
if [[ "$DOCKER_MAJOR" -lt 24 ]]; then
  die "Docker 24+ is required (found $DOCKER_VERSION). Please upgrade Docker."
fi

if ! docker compose version &>/dev/null; then
  die "Docker Compose v2 is required. It is bundled with Docker Desktop and Docker Engine 24+."
fi

for port in 80 443; do
  if ss -tlnH "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    die "Port $port is already in use. Stop whatever is running on it, then re-run this script."
  fi
done

success "Pre-flight checks passed."
echo ""

# ── Prompts ─────────────────────────────────────────────────────────────────

read -rp "$(echo -e "${BOLD}Your domain${RESET} (e.g. app.yourdomain.com): ")" DOMAIN </dev/tty
[[ -z "$DOMAIN" ]] && die "Domain cannot be empty."

echo ""
info "Google OAuth (optional — skip to use email/password auth only)"
read -rp "  GOOGLE_CLIENT_ID   [leave blank to skip]: " GOOGLE_CLIENT_ID </dev/tty
GOOGLE_CLIENT_SECRET=""
if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
  read -rp "  GOOGLE_CLIENT_SECRET: " GOOGLE_CLIENT_SECRET </dev/tty
  [[ -z "$GOOGLE_CLIENT_SECRET" ]] && die "GOOGLE_CLIENT_SECRET cannot be empty when GOOGLE_CLIENT_ID is set."
fi

echo ""

# ── Generate / reuse secrets (idempotent) ────────────────────────────────────
# Persist generated secrets so a re-run (or a partial run + retry) REUSES them.
# Regenerating OPENCLAW_TOKEN on a re-run desyncs the backend from the already-
# running OpenClaw (→ 401 Unauthorized on every agent call); regenerating
# BETTER_AUTH_SECRET separately invalidates every logged-in session.
PERSIST_ENV=/root/.damn-dev/secrets.env
mkdir -p /root/.damn-dev
# shellcheck disable=SC1090
[ -f "$PERSIST_ENV" ] && . "$PERSIST_ENV"

# Belt-and-braces: if OpenClaw already has a config, its gateway.auth.token is the
# ground truth (that's what OpenClaw validates against) — prefer it over anything
# persisted or freshly generated, so the backend can never drift from a running gateway.
if [ -f /root/.openclaw/openclaw.json ]; then
  EXISTING_OC_TOKEN=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' /root/.openclaw/openclaw.json | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  [ -n "${EXISTING_OC_TOKEN:-}" ] && OPENCLAW_TOKEN="$EXISTING_OC_TOKEN"
fi

BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET:-$(openssl rand -hex 32)}
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET:-$(openssl rand -hex 32)}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN:-$(openssl rand -hex 32)}
SHELL_EXECUTOR_SECRET=${SHELL_EXECUTOR_SECRET:-$(openssl rand -hex 32)}
EGRESS_PROXY_SECRET=${EGRESS_PROXY_SECRET:-$(openssl rand -hex 32)}
OPENCLAW_URL="http://openclaw:18789"

# Persist for the next run (0600). Chowned to uid 1000 later alongside the rest of
# /root/.damn-dev so the backend can also read it.
cat > "$PERSIST_ENV" <<PERSIST_EOF
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
SHELL_EXECUTOR_SECRET=${SHELL_EXECUTOR_SECRET}
EGRESS_PROXY_SECRET=${EGRESS_PROXY_SECRET}
PERSIST_EOF
chmod 600 "$PERSIST_ENV"

# ── Write .env ───────────────────────────────────────────────────────────────

ENV_FILE="/tmp/damn-dev-install.env"

cat > "$ENV_FILE" <<EOF
GHCR_OWNER=lethodeter
DOMAIN=${DOMAIN}
BETTER_AUTH_URL=https://${DOMAIN}
BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
OPENCLAW_URL=${OPENCLAW_URL}
OPENCLAW_TOKEN=${OPENCLAW_TOKEN}
SHELL_EXECUTOR_SECRET=${SHELL_EXECUTOR_SECRET}
EGRESS_PROXY_SECRET=${EGRESS_PROXY_SECRET}
OPENCLAW_CONTAINER_NAME=openclaw
DAMNDEV_OUTBOUND_SECRET=${DAMNDEV_OUTBOUND_SECRET}
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
REGISTRATION_MODE=closed
DAMNDEV_CONTAINERIZED=true
DAMNDEV_INSTALL_PATH=docker-vps
DAMN_DEV_VERSION_URL=https://damn.dev/version.json
EOF

success ".env written to $ENV_FILE"

# ── OpenClaw ──────────────────────────────────────────────────────────────────

setup_openclaw_vps() {
  if curl -sf http://localhost:18789/health > /dev/null 2>&1; then
    info "OpenClaw already running."
    return 0
  fi

  mkdir -p "$HOME/.openclaw"

  # Note: webhookUrl uses container-to-container DNS (`http://backend:3001`)
  # because both compose files (docker-compose.openclaw.yml + docker-compose.prod.yml)
  # live in /opt/damn-dev/ and share project name `damn-dev` → shared default
  # network. For the docker-local equivalent, see damn-dev-install/install-docker.sh
  # (served at install.damn.dev/docker) which uses `http://host.docker.internal:${PORT}`
  # (host-gateway pattern).
  # Sandbox kept `off` for docker-vps: OpenClaw container has docker CLI via
  # the hardened image but no /var/run/docker.sock mount → `non-main` would crash.
  cat > "$HOME/.openclaw/openclaw.json" << OPENCLAW_EOF
{
  "gateway": {
    "auth": { "token": "${OPENCLAW_TOKEN}" },
    "bind": "lan",
    "mode": "local",
    "http": {
      "endpoints": {
        "responses": { "enabled": true }
      }
    },
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
      "sandbox": { "mode": "off" },
      "timeoutSeconds": 600
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
          "webhookUrl": "http://backend:3001/webhooks/openclaw",
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

  mkdir -p /opt/damn-dev

  cat > /opt/damn-dev/docker-compose.openclaw.yml <<COMPOSE_MARKER
services:
  openclaw:
    # Hardened image bakes the damndev plugin at /home/node/openclaw-plugins/damndev
    # (owned uid=1000, matches the container's default node user). Vanilla
    # ghcr.io/openclaw/openclaw:latest has NO damndev plugin → heartbeats break,
    # openclaw.json references it → crash loop. See PRD.md "SESSION — OpenClaw
    # Health Banner + Install-Mode-Aware Restart (0.9.15)" and CLAUDE.md
    # "OpenClaw Integration Rules" for the empirical debugging of this.
    image: ghcr.io/lethodeter/openclaw-hardened:latest
    container_name: openclaw
    ports:
      - "127.0.0.1:18789:18789"
    volumes:
      - ${HOME}/.openclaw:/home/node/.openclaw
    environment:
      - OPENCLAW_GATEWAY_BIND=lan
    restart: unless-stopped
COMPOSE_MARKER

  docker compose -f /opt/damn-dev/docker-compose.openclaw.yml up -d
  info "Waiting for OpenClaw..."
  for i in $(seq 1 30); do
    sleep 2
    if curl -sf http://localhost:18789/health > /dev/null 2>&1; then
      success "OpenClaw ready."
      return 0
    fi
    printf "."
  done
  echo ""
  die "OpenClaw did not start in time (waited 60s). Check: docker logs openclaw"
}

setup_openclaw_vps

# ── Write deployment files ────────────────────────────────────────────────────

INSTALL_DIR="/opt/damn-dev"
mkdir -p "$INSTALL_DIR"

cp "$ENV_FILE" "$INSTALL_DIR/.env"

cat > "$INSTALL_DIR/docker-compose.prod.yml" <<'COMPOSE_EOF'
services:
  init-permissions:
    image: alpine:3.19
    command: sh -c "chown -R 1000:1000 /data && chmod 777 /data"
    volumes:
      - damn_db:/data

  shell-executor:
    # Contained ops shell executor (Containment Floor H3). Agent shell runs HERE, not
    # in the backend — so secrets are not mounted (ENOENT) and egress has no route
    # (exec-net is internal:true). The Docker daemon creates it (no --privileged, no
    # docker.sock). See CONTAINMENT_EXECUTOR_PLAN.md.
    image: ghcr.io/${GHCR_OWNER}/damn-dev-shell-executor:latest
    restart: unless-stopped
    environment:
      SHELL_EXECUTOR_SECRET: ${SHELL_EXECUTOR_SECRET}
      SHELL_EXECUTOR_PORT: "9000"
    networks:
      - exec-net
    volumes:
      # ONLY agent work dirs. The parent /root/.openclaw (openclaw.json with decrypted
      # provider keys, .env) is NOT bound, so secrets are absent. NEVER mount
      # /root/.damn-dev, the full /root/.openclaw, or damn_db here.
      - /root/.openclaw/agents:/home/node/.openclaw/agents
    tmpfs:
      - /tmp

  egress-proxy:
    # Sovereign egress proxy (H1 / Reliability ladder R2 — ee/, entitlement-gated).
    # Derives each connection's destination host (HTTP CONNECT / TLS SNI), asks the
    # backend control plane for a verdict (the ONE kernel decide() on host:), then
    # splices or refuses. No TLS MITM. Per AD-E14 it degrades to its last-known
    # allowlist when the backend is unreachable — it never opens.
    #
    # STAGED: DEFINED here for the cutover but profile-gated, so a default
    # `docker compose up -d` does NOT start it — no image pull, so a fresh install
    # comes up cleanly even before the GHCR image is published (degrade-to-safe). The
    # route-cutover session enables it (COMPOSE_PROFILES=egress), must publish the image
    # first, and only then reroutes the backend to make egress-proxy its ONLY exit
    # (AD-E12). Until then this is fully inert. See ENFORCEMENT_ENGINE_SCOPING.md "H1".
    profiles: ["egress"]
    image: ghcr.io/${GHCR_OWNER}/damn-dev-egress-proxy:latest
    restart: unless-stopped
    environment:
      EGRESS_PROXY_SECRET: ${EGRESS_PROXY_SECRET}
      EGRESS_PROXY_PORT: "9100"
      EGRESS_BACKEND_URL: http://backend:3001
    networks:
      - egress-net
      - default

  backend:
    image: ghcr.io/${GHCR_OWNER}/damn-dev-backend:latest
    restart: unless-stopped
    depends_on:
      init-permissions:
        condition: service_completed_successfully
    environment:
      NODE_ENV: production
      PORT: "3001"
      DATABASE_URL: file:/data/damn.db
      BETTER_AUTH_URL: https://${DOMAIN}
      BETTER_AUTH_SECRET: ${BETTER_AUTH_SECRET}
      OPENCLAW_URL: ${OPENCLAW_URL:-http://openclaw:18789}
      OPENCLAW_TOKEN: ${OPENCLAW_TOKEN}
      DAMNDEV_OUTBOUND_SECRET: ${DAMNDEV_OUTBOUND_SECRET}
      GOOGLE_CLIENT_ID: ${GOOGLE_CLIENT_ID:-}
      GOOGLE_CLIENT_SECRET: ${GOOGLE_CLIENT_SECRET:-}
      REGISTRATION_MODE: ${REGISTRATION_MODE:-closed}
      DAMNDEV_CONTAINERIZED: "true"
      SHELL_EXECUTOR_URL: http://shell-executor:9000
      SHELL_EXECUTOR_SECRET: ${SHELL_EXECUTOR_SECRET}
      DAMNDEV_INSTALL_PATH: docker-vps
      DAMN_DEV_VERSION_URL: https://damn.dev/version.json
      OPENCLAW_CONTAINER_NAME: ${OPENCLAW_CONTAINER_NAME:-openclaw}
      DOCKER_SOCKET_PROXY_URL: http://docker-socket-proxy:2375
      # H1 egress proxy control-plane HMAC secret (the proxy authenticates with it).
      # Inert until an H1 license + an egress policy engage the proxy.
      EGRESS_PROXY_SECRET: ${EGRESS_PROXY_SECRET}
    networks:
      - default
      - proxy-net
      - exec-net
      # Staged H1 link to the egress proxy. The backend KEEPS its direct egress
      # (the `default` NAT network) this session — the route cutover is the follow-on.
      - egress-net
    volumes:
      - damn_db:/data
      - /root/.openclaw:/home/node/.openclaw
      - /root/.damn-dev:/home/node/.damn-dev
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:3001/health', r => process.exit(r.statusCode === 200 ? 0 : 1))"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s

  frontend:
    image: ghcr.io/${GHCR_OWNER}/damn-dev-frontend:latest
    restart: unless-stopped
    depends_on:
      backend:
        condition: service_healthy

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      DOMAIN: ${DOMAIN}
    depends_on:
      - backend
      - frontend

  watchtower:
    # Digest-pinned: this container has full Docker socket access. Same security
    # tier as docker-socket-proxy below — never use a mutable tag here. Bumping
    # requires fetching the new digest from Docker Hub and updating all 3 install
    # paths (this file + damn-dev/scripts/install.sh + damn-dev-cloud/provisioning/
    # src/lib/provision.ts) in lockstep. See CLAUDE.md "Watchtower digest pin".
    image: containrrr/watchtower@sha256:6dd50763bbd632a83cb154d5451700530d1e44200b268a4e9488fefdfcf2b038
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      WATCHTOWER_HTTP_API_UPDATE: "true"
      WATCHTOWER_HTTP_API_TOKEN: ${OPENCLAW_TOKEN}
      WATCHTOWER_POLL_INTERVAL: "0"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "false"
      WATCHTOWER_NO_STARTUP_MESSAGE: "true"
      DOCKER_API_VERSION: "1.40"
    labels:
      - "com.centurylinklabs.watchtower.enable=false"

  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy@sha256:1f3a6f303320723d199d2316a3e82b2e2685d86c275d5e3deeaf182573b47476
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    environment:
      POST: 1
      ALLOW_RESTARTS: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    tmpfs:
      - /run
      - /tmp
    networks:
      - proxy-net
    labels:
      - "com.centurylinklabs.watchtower.enable=false"

networks:
  proxy-net:
    internal: true
  exec-net:
    internal: true
  # Private backend↔egress-proxy link (H1). internal:true: nothing routes off-box
  # over it — the proxy's own internet egress rides the default (NAT) network.
  egress-net:
    internal: true

volumes:
  damn_db:
  caddy_data:
  caddy_config:
COMPOSE_EOF

cat > "$INSTALL_DIR/Caddyfile" <<'CADDY_EOF'
{$DOMAIN} {
    handle /api/* {
        reverse_proxy backend:3001
    }

    handle /trpc/* {
        reverse_proxy backend:3001
    }

    handle /webhooks/* {
        reverse_proxy backend:3001
    }

    handle /ws {
        reverse_proxy backend:3001
    }

    handle {
        reverse_proxy frontend:80
    }
}
CADDY_EOF

success "Deployment files written to $INSTALL_DIR"

# ── Build & start ─────────────────────────────────────────────────────────────

info "Pulling and starting containers (this takes ~2 minutes on first run)..."
# Ensure the agent work-dir tree exists + is owned by uid 1000 BEFORE compose up, so
# the backend (full /root/.openclaw mount) and the shell-executor (agents-only mount)
# can both read/write it. Without this Docker auto-creates the bind source root-owned
# and the backend (uid 1000) can't create agent dirs. See CONTAINMENT_EXECUTOR_PLAN.md.
mkdir -p /root/.openclaw/agents && chown -R 1000:1000 /root/.openclaw
# The backend (uid 1000) mounts /root/.damn-dev and writes secrets.key there to
# AES-encrypt provider/workspace secrets. Docker auto-creates the bind source
# root-owned, so without this chown uid 1000 can't create secrets.key → provider
# keys silently fail to persist. Runs AFTER PERSIST_ENV is written above.
mkdir -p /root/.damn-dev && chown -R 1000:1000 /root/.damn-dev

docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" --env-file "$INSTALL_DIR/.env" up -d

echo ""
echo "──────────────────────────────────"
success "damn.dev is live at ${BOLD}https://${DOMAIN}${RESET}"
echo ""
echo "  First login:  create an account at https://${DOMAIN}"
echo "  View logs:    docker compose -f $INSTALL_DIR/docker-compose.prod.yml logs -f"
echo "  Stop:         docker compose -f $INSTALL_DIR/docker-compose.prod.yml down"
echo ""
