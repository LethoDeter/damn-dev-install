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

# ── Enterprise (paid) modules — optional ─────────────────────────────────────
# EE_DELIVERY_SCOPING.md §6b C6. Governance and observation are FREE forever and
# need nothing here: skipping leaves the install byte-for-byte as it was before
# this block existed — no docker login, no COMPOSE_PROFILES, and the ee-loader
# service is not even resolved by compose, so the private image is never
# referenced or pulled.
#
# A paying customer has a pull-only registry.damn.dev account (one per customer,
# minted alongside their licence by scripts/licenses.mjs, revocable on its own).
# Presetting EE_REGISTRY_USERNAME/EE_REGISTRY_PASSWORD in the environment skips
# the prompts for an unattended install.
EE_REGISTRY_USERNAME="${EE_REGISTRY_USERNAME:-}"
EE_REGISTRY_PASSWORD="${EE_REGISTRY_PASSWORD:-}"
info "Enterprise modules (optional — press Enter to skip; governance is free forever)"
if [[ -z "$EE_REGISTRY_USERNAME" ]]; then
  read -rp "  registry.damn.dev username [leave blank to skip]: " EE_REGISTRY_USERNAME </dev/tty
fi
if [[ -n "$EE_REGISTRY_USERNAME" && -z "$EE_REGISTRY_PASSWORD" ]]; then
  # -s: never echoed to the terminal, and never passed as an argument to anything
  # (see the docker login below — it goes in on stdin, so it stays out of `ps`).
  read -rsp "  registry.damn.dev password: " EE_REGISTRY_PASSWORD </dev/tty
  echo ""
  [[ -z "$EE_REGISTRY_PASSWORD" ]] && die "The registry password cannot be empty. Re-run and leave the username blank to install without paid modules."
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

# Belt-and-braces: openclaw.json is the ground truth for BOTH shared secrets, because
# for each one the OTHER side is the party we cannot reconfigure from here —
#   gateway.auth.token          → what OpenClaw VALIDATES backend→gateway calls against
#   damndev inboundSharedSecret → what the plugin SIGNS gateway→backend calls with
# so prefer both over anything persisted or freshly generated. Without the second
# read-back a re-run against a healthy OpenClaw (which skips the openclaw.json write)
# handed the backend a fresh DAMNDEV_OUTBOUND_SECRET while the plugin kept signing with
# the old one → every /skills/exec 401'd with no self-heal.
# `if`, not `[ … ] && …`: under `set -e` a failed test as the last command of the block
# aborts the whole install.
if [ -f /root/.openclaw/openclaw.json ]; then
  EXISTING_OC_TOKEN=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' /root/.openclaw/openclaw.json | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [ -n "${EXISTING_OC_TOKEN:-}" ]; then OPENCLAW_TOKEN="$EXISTING_OC_TOKEN"; fi
  EXISTING_INBOUND_SECRET=$(grep -o '"inboundSharedSecret"[[:space:]]*:[[:space:]]*"[^"]*"' /root/.openclaw/openclaw.json | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [ -n "${EXISTING_INBOUND_SECRET:-}" ]; then DAMNDEV_OUTBOUND_SECRET="$EXISTING_INBOUND_SECRET"; fi
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
# H1 sovereign egress proxy — OpenClaw's outbound proxy URL. EMPTY = inert (Node
# ignores an empty HTTP(S)_PROXY, so OpenClaw egresses directly, as it always has).
# Set to http://egress-proxy:9100 to route the agent runtime through the proxy; see
# the enable runbook (publish the image → COMPOSE_PROFILES=egress → set this →
# capabilities.egress: 'audit'). Read on every recreate, so a backend-initiated
# OpenClaw restart keeps it.
OPENCLAW_EGRESS_PROXY_URL=
EOF

# Paid install only: persist the profile so EVERY later `docker compose --env-file`
# (restart, update, manual up) keeps delivering paid modules. Compose reads
# COMPOSE_PROFILES out of the env file — verified against Compose v2/v5. NEVER write
# the registry password here: docker keeps its own credential store, and this file
# is read by every container in the stack.
if [[ -n "$EE_REGISTRY_USERNAME" ]]; then
  echo "COMPOSE_PROFILES=ee" >> "$ENV_FILE"
fi

success ".env written to $ENV_FILE"

# ── OpenClaw ──────────────────────────────────────────────────────────────────

# OpenClaw health, independent of the published port.
#
# VERIFIED 2026-07-29 (moby source + moby#36174 + empirical): a container attached
# ONLY to an `internal: true` network never gets a gateway endpoint, so Docker never
# programs the host→container DNAT — a `ports:` mapping there is a SILENT no-op
# (accepted, listed in HostConfig.PortBindings, never realised, no warning). So once
# the H1 egress fence below is applied, `curl localhost:18789/health` stops answering
# while OpenClaw is perfectly healthy. Probe from INSIDE the container as the
# fallback; `node` is guaranteed present in the image.
openclaw_healthy() {
  curl -sf http://localhost:18789/health > /dev/null 2>&1 && return 0
  docker exec openclaw node -e \
    "require('http').get('http://127.0.0.1:18789/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" \
    > /dev/null 2>&1
}

setup_openclaw_vps() {
  # Also the guard that makes a re-run non-destructive: a healthy OpenClaw means we
  # do NOT rewrite docker-compose.openclaw.yml, which is what preserves an operator's
  # H1 fence edit (see the fence note in the compose file below).
  if openclaw_healthy; then
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
  "channels": {
    "damndev": { "healthMonitor": { "enabled": true, "interval": 300 } }
  },
  "agents": {
    "defaults": {
      "sandbox": { "mode": "off" },
      "timeoutSeconds": 600
    },
    "list": []
  },
  "skills": {
    "workshop": { "autonomous": { "enabled": false }, "approvalPolicy": "pending" }
  },
  "update": { "checkOnStart": false, "auto": { "enabled": false } },
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
    # ── config self-heal, before the gateway validates anything ────────────────
    # OpenClaw >= 2026.6.11 hard-REJECTS a pre-6.11 config (agents.defaults:
    # Invalid input) and refuses to start, so an existing install cannot boot its
    # way onto the new image unaided. doctor --fix does the whole migration in one
    # pass: embeddedPi becomes embeddedAgent, openai-codex/* folds into openai/* +
    # agentRuntime, and cron + per-agent auth profiles import into SQLite, keeping
    # openclaw.json.bak. Verified: an un-migrated real config reached ready in 18s.
    #
    # Overrides command ONLY, never entrypoint. The image entrypoint is tini -s --
    # and replacing it would drop the init that reaps zombies. Verified PID 1 is
    # still tini with this form.
    #
    # Separator is ';' not '&&': a doctor failure must not stop the gateway. If the
    # config is already fine the gateway starts regardless; if it is broken the
    # gateway's own strict validation fails loudly, which is the honest gate.
    # Doctor converges in two passes and then changes nothing (verified on a third).
    command:
      - sh
      - -c
      - openclaw doctor --fix; rc=\$\$?; echo "[boot] openclaw doctor --fix exit=\$\$rc"; exec node openclaw.mjs gateway
    ports:
      # Convenience/diagnostic mapping. A SILENT NO-OP once the H1 fence below is
      # applied (a container on an internal:true network gets no gateway endpoint, so
      # Docker never programs the DNAT). Nothing may depend on it — the installer
      # probes via docker exec, and the backend reaches OpenClaw over container DNS
      # (OPENCLAW_URL=http://openclaw:18789), not through this port.
      - "127.0.0.1:18789:18789"
    # Map the Docker host so a HOST-LOCAL model server (Ollama/vLLM on this VPS,
    # e.g. a GPU box) is reachable. resolveOllamaBaseUrl() in lib/openclaw.ts writes
    # http://host.docker.internal:11434/v1 for docker-vps, but on Linux that name does
    # NOT resolve inside a container unless it is mapped here — so before this line the
    # URL it wrote was unresolvable and any vllm/* model on docker-vps was dead config.
    # Grants nothing new: the container could already reach the host IP over the default
    # bridge; this only gives it a name. Harmless when no local model server exists.
    #
    # ⚠️ IN TENSION WITH THE H1 FENCE: once `- default` is removed below, OpenClaw has
    # only the internal egress-net, which has no gateway — so the host bridge is
    # unreachable and a host-local model provider stops working. Fence and host-local
    # models are mutually exclusive by design (the fence removes every non-proxy route).
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ${HOME}/.openclaw:/home/node/.openclaw
    environment:
      - OPENCLAW_GATEWAY_BIND=lan
      # ── H1 sovereign egress proxy (docker-vps only) ───────────────────────────
      # CEILING (the only sentence the product may use for this): host-granular
      # egress control for the agent runtime, enforced by the Docker daemon's network
      # topology on docker-vps. It records or blocks connections by destination host.
      # It does NOT inspect content and does NOT stop exfiltration through an allowed
      # host. In 'audit' mode: recording only — nothing is blocked yet. This holds on
      # docker-vps ONLY; on docker-local/Tauri OpenClaw's container mounts docker.sock
      # (so the topology is escapable from inside) and on npm OpenClaw is a native
      # process with no container at all — never extend the claim to those paths.
      #
      # Explicit proxy, NOT transparent interception: OpenClaw is told to send
      # outbound traffic to egress-proxy:9100, which derives the destination host
      # (CONNECT / TLS SNI), asks the backend for the ONE kernel decide() verdict,
      # then splices or refuses. No TLS MITM, no iptables, no NET_ADMIN.
      #
      # EMPTY BY DEFAULT = PROVABLY INERT. Node installs its env-proxy agent only
      # when HTTP_PROXY/HTTPS_PROXY is non-empty (verified in Node v24
      # lib/internal/process/pre_execution.js), so an unset value changes nothing —
      # a fresh install behaves exactly as before. To engage, set
      # OPENCLAW_EGRESS_PROXY_URL=http://egress-proxy:9100 in /opt/damn-dev/.env
      # (see the enable runbook) — the value is read on every recreate, including a
      # backend-initiated restartOpenClaw().
      - HTTPS_PROXY=\${OPENCLAW_EGRESS_PROXY_URL:-}
      - HTTP_PROXY=\${OPENCLAW_EGRESS_PROXY_URL:-}
      # Node 24: makes fetch() (v24.0+) and http/https.request() (v24.5+) honour the
      # proxy env. It does NOT cover raw net/tls sockets, so anything speaking its own
      # socket is unproxied — with the fence applied such traffic loses its route
      # entirely rather than escaping (fail-closed, but a visible regression).
      - NODE_USE_ENV_PROXY=1
      # LOAD-BEARING: OpenClaw must keep reaching http://backend:3001/webhooks/openclaw
      # directly. Without `backend` here that call is sent to the egress proxy, which
      # refuses it as non-allowlisted, and every agent reply + heartbeat delivery dies.
      # host.docker.internal is defence-in-depth, NOT currently load-bearing: it only
      # matters IF a host-local model server exists (see extra_hosts above). With one,
      # this keeps its calls direct instead of routing them at the internet proxy.
      # With none, the entry is inert. Listed so enabling a local provider later cannot
      # silently break it.
      - NO_PROXY=backend,localhost,127.0.0.1,host.docker.internal,.local
    networks:
      # damn-dev_default — the NAT exit OpenClaw has always used, and the network the
      # backend shares with it for container DNS.
      #
      # ↓↓ THE H1 FENCE ↓↓  Deleting this ONE line makes egress-proxy the ONLY exit:
      # egress-net is internal:true, so there is no other route off-box and an agent
      # that unsets HTTPS_PROXY gets no internet at all rather than ungated internet.
      # That is what makes the guarantee topological instead of cooperative.
      #
      # It is NOT removed here on purpose: egress-proxy is profile-gated
      # (COMPOSE_PROFILES=egress) so a default install does not start it, and removing
      # this line while the proxy is down would leave OpenClaw with NO egress at all.
      # Remove it only as the last step of the enable runbook, after the proxy is up.
      - default
      - egress-net
    restart: unless-stopped

networks:
  # Declared with the SAME key (egress-net) and the SAME internal flag as
  # docker-compose.prod.yml. Both files live in /opt/damn-dev so they share the
  # compose project name `damn-dev`; same project + same key ⇒ both resolve to the
  # ONE damn-dev_egress-net network, whichever file creates it first. This is the
  # same mechanism the two files already rely on for damn-dev_default. Keep the two
  # declarations identical — if they diverge, compose refuses to adopt the network.
  egress-net:
    internal: true
COMPOSE_MARKER

  docker compose -f /opt/damn-dev/docker-compose.openclaw.yml up -d
  info "Waiting for OpenClaw..."
  for i in $(seq 1 30); do
    sleep 2
    if openclaw_healthy; then
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

  shell-supervisor:
    # Per-agent shell executors (Containment Floor H3.5 — SPIKE, see
    # CONTAINMENT_EXECUTOR_PLAN.md §14). Creates one executor container per agent,
    # each mounting ONLY that agent's own directory, so the cross-agent read that the
    # shared executor above can only call "advisory" becomes ENOENT — absent from the
    # namespace, not merely forbidden by policy.
    #
    # WHY IT HOLDS THE SOCKET. Per-agent means containers on demand, and the backend
    # deliberately cannot create containers here: docker-socket-proxy below is
    # POST=1 + ALLOW_RESTARTS=1 because CONTAINERS=1 carries no method filter and
    # would open create/delete/exec on ANY container on the host. This service exists
    # so that rule survives. NEVER "fix" per-agent executors by adding CONTAINERS=1.
    #
    # >> NEVER ADD exec-net TO THIS SERVICE. On a shared network a compromised agent
    # >> shell could call /ensure with a PEER's agentId, get a container mounting that
    # >> peer's directory on a network it can already reach, and drive it —
    # >> reconstructing the exact cross-agent read this rung exists to prevent,
    # >> through the component built to prevent it. sup-net, and nothing else.
    #
    # SPIKE, NOT A SHIP — INERT ON A DEFAULT INSTALL, via two independent gates:
    # profiles-gated (so a default `docker compose up -d` never resolves it, and no
    # image is pulled) AND the backend's SHELL_SUPERVISOR_URL below ships EMPTY
    # (empty => the shared-executor path verbatim). Both must be flipped. Holding the
    # Docker socket puts this in the TRUSTED tier — a supervisor compromise is
    # equivalent to host compromise; see SECURITY_MODEL.md "Trusted" item 2b.
    #
    # No new secret: it reuses SHELL_EXECUTOR_SECRET as the ROOT, and hands each
    # executor only HMAC(root, itsOwnAgentId) so one cannot sign for a peer.
    profiles: ["h35"]
    image: ghcr.io/${GHCR_OWNER}/damn-dev-shell-supervisor:latest
    restart: unless-stopped
    environment:
      SHELL_EXECUTOR_SECRET: ${SHELL_EXECUTOR_SECRET}
      SHELL_SUPERVISOR_PORT: "9001"
      SHELL_EXECUTOR_IMAGE: ghcr.io/${GHCR_OWNER}/damn-dev-shell-executor:latest
      # Compose prefixes networks with the project name; executors are created through
      # the Docker API, not by compose, so the real name is needed here.
      EXEC_NETWORK: ${COMPOSE_PROJECT_NAME:-damn-dev}_exec-net
      # HOST path — bind sources are resolved by the daemon, not inside this
      # container. Only <this>/<agentId> is ever mounted, never the parent.
      AGENTS_HOST_DIR: /root/.openclaw/agents
      AGENTS_CONTAINER_DIR: /home/node/.openclaw/agents
    networks:
      - sup-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    labels:
      - "com.centurylinklabs.watchtower.enable=false"

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

  ee-loader:
    # Paid-module delivery (EE_DELIVERY_SCOPING.md §6b C3). Copies ee/dist out of the
    # PRIVATE damn-dev-ee image into a named volume; the backend mounts that volume
    # read-only at /app/ee — exactly where loadEeEgress() already looks. ZERO backend
    # code change: the seam (apps/backend/src/lib/egressGate.ts) predates this and
    # already tries both walk-up depths.
    #
    # PROFILE-GATED, and that is the whole degrade-safe property. With no profile set
    # compose does not resolve this service at all, so a FREE install never references
    # the private image and never attempts a pull it has no credentials for. Verified
    # empirically: with the profile off "docker compose pull" succeeds and omits this
    # image entirely, even while registry.damn.dev does not resolve at all.
    #
    # NEVER give the backend a depends_on for this service. Verified: with the profile
    # off, compose rejects the WHOLE project with "service backend depends on undefined
    # service ee-loader: invalid compose project" — that breaks every free install
    # outright rather than gracefully. The start ordering it would buy is not needed:
    # resolveEgressEngagement() re-imports the module on EVERY call (no memoisation),
    # so a backend that raced ahead of this copy self-heals on its next call.
    #
    # No restart policy on purpose: this is a one-shot that must exit 0, not a service.
    # Paid install: COMPOSE_PROFILES=ee docker compose up -d
    profiles: ["ee"]
    image: registry.damn.dev/damn-dev-ee:latest
    # rm first, so a module REMOVED in a later release cannot linger in the volume.
    command: sh -c "rm -rf /target/* && cp -a /ee/. /target/"
    volumes:
      - ee_dist:/target

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
      # H3.5 per-agent executors (SPIKE). SHIPS EMPTY, and that is the whole
      # inert-by-default property: empty => ContainerExecutor takes the shared-executor
      # path verbatim and never calls a supervisor. DISTINCT from SHELL_EXECUTOR_URL
      # above — that names the shared service; this switches the resolution MODE to
      # per-agent. Setting it without starting the h35 profile is fail-closed, not
      # fail-open: every shell call is refused because no supervisor answers /ensure.
      SHELL_SUPERVISOR_URL: ${SHELL_SUPERVISOR_URL:-}
      DAMNDEV_INSTALL_PATH: docker-vps
      DAMN_DEV_VERSION_URL: https://damn.dev/version.json
      OPENCLAW_CONTAINER_NAME: ${OPENCLAW_CONTAINER_NAME:-openclaw}
      DOCKER_SOCKET_PROXY_URL: http://docker-socket-proxy:2375
      # H1 egress proxy control-plane HMAC secret (the proxy authenticates with it).
      # Inert until an H1 license + an egress policy engage the proxy.
      EGRESS_PROXY_SECRET: ${EGRESS_PROXY_SECRET}
      # P0c — the address the BROWSER (camoufox: a child process of this backend, with
      # its own network stack, so it is NOT covered by proxying the backend itself)
      # routes through when wire-level egress is ENGAGED. Inert on its own:
      # resolveBrowserProxy() also requires resolveEgressEngagement().engaged.
      EGRESS_PROXY_URL: http://egress-proxy:9100
      # ── P0b — the BACKEND's OWN outbound traffic ────────────────────────────
      # This is what carries HTTP skill dispatch (skillToolDispatcher) and
      # direct-gateway model calls (anthropic/openrouter/claude-code/ollama). Proxying
      # OpenClaw and the browser leaves this path open, so the claim "the agent cannot
      # reach that host" is false without it.
      #
      # DISTINCT from EGRESS_PROXY_URL above. That one is an ADDRESS the browser code
      # reads, gated by resolveEgressEngagement(), which is why shipping it real is
      # safe. THIS one is consumed by NODE ITSELF with no engagement gate, so it ships
      # EMPTY: Node installs its env-proxy agent only when HTTP(S)_PROXY is non-empty
      # (v24 lib/internal/process/pre_execution.js), making an unset value a no-op.
      HTTPS_PROXY: ${BACKEND_EGRESS_PROXY_URL:-}
      HTTP_PROXY: ${BACKEND_EGRESS_PROXY_URL:-}
      # Covers fetch (v24.0+) and http/https.request (v24.5+). NOT raw net/tls sockets.
      NODE_USE_ENV_PROXY: "1"
      # LOAD-BEARING: every container-internal peer the backend talks to. Miss one and
      # that call is sent to the egress proxy, refused as non-allowlisted, and the
      # failure reads as a proxy bug rather than a config gap. `watchtower` is the
      # non-obvious one — the in-product Update button calls http://watchtower:8080.
      NO_PROXY: openclaw,shell-executor,docker-socket-proxy,watchtower,egress-proxy,backend,frontend,localhost,127.0.0.1,host.docker.internal,.local
    networks:
      # ↓↓ THE H1 BACKEND FENCE ↓↓ Deleting this ONE line makes egress-proxy the only
      # exit for the backend as well. NOT removed here: egress-proxy is profile-gated,
      # so cutting this while the proxy is down leaves the backend with NO egress at
      # all (the same structural collision as the OpenClaw fence — Compose cannot
      # conditionally detach a network). Remove it only as a deliberate runbook step,
      # after the proxy is up AND BACKEND_EGRESS_PROXY_URL is set.
      - default
      - proxy-net
      - exec-net
      - egress-net
      # H3.5: reaches shell-supervisor. Harmless while the h35 profile is off — an
      # empty internal network with one member. The backend is the ONLY service that
      # may be on both this and exec-net; the supervisor must never be on exec-net.
      - sup-net
    volumes:
      - damn_db:/data
      - /root/.openclaw:/home/node/.openclaw
      - /root/.damn-dev:/home/node/.damn-dev
      # Paid (ee/) modules, delivered by the profile-gated ee-loader above. READ-ONLY:
      # the backend loads these, never writes them. On a free install the volume is
      # simply empty, the dynamic import fails, and the seam reports not-engaged —
      # byte-for-byte the behaviour before this mount existed.
      - ee_dist:/app/ee:ro
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
  # Private backend<->shell-supervisor link (H3.5). Its whole job is to be a network
  # executors are NOT on: the supervisor can mint a container mounting any agent's
  # directory, so an executor that could reach it could ask for a peer's.
  sup-net:
    internal: true
  # Private backend↔egress-proxy link (H1). internal:true: nothing routes off-box
  # over it — the proxy's own internet egress rides the default (NAT) network.
  egress-net:
    internal: true

volumes:
  damn_db:
  caddy_data:
  caddy_config:
  # Paid (ee/) modules — populated ONLY by the profile-gated ee-loader. Empty on a
  # free install, which is exactly the pre-existing not-engaged behaviour.
  ee_dist:
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

# Paid install only: authenticate to the private paid-artifact registry so the
# profile-gated ee-loader can pull. A free install never reaches this branch and
# never authenticates to anything. --password-stdin, never --password: an argument
# would be visible in `ps` on a shared box and land in root's shell history.
#
if [[ -n "$EE_REGISTRY_USERNAME" ]]; then
  info "Authenticating to registry.damn.dev for enterprise modules..."
  printf '%s' "$EE_REGISTRY_PASSWORD" \
    | docker login registry.damn.dev --username "$EE_REGISTRY_USERNAME" --password-stdin \
    || die "docker login registry.damn.dev failed. Check the username/password you were issued, or re-run and leave the username blank to install without paid modules."

  # Run the one-shot loader explicitly, with the profile named on the command line.
  # COMPOSE_PROFILES in .env is what carries the setting into every LATER compose
  # invocation on this box; naming it here means THIS run does not depend on which
  # Compose version the box happens to have. It also lands /app/ee before the backend
  # starts, rather than racing it.
  info "Delivering enterprise modules..."
  docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" --env-file "$INSTALL_DIR/.env" --profile ee up -d ee-loader \
    || die "Could not pull the enterprise modules from registry.damn.dev. The credential authenticated, so this is likely a network or registry issue — re-run once it is reachable."
fi

# ── Block the cloud metadata endpoint for containers ────────────────────────
#
# 169.254.169.254 exists on EVERY cloud VPS. On Hetzner it serves this instance's
# cloud-init; on AWS it serves IAM role credentials outright. An agent that reaches
# it — via a redirect its browser followed, or a shell command — reads whatever the
# provider puts there. `assertSafeUrl` guards the app layer; this is the layer
# beneath it, so a caller nobody has thought of yet is covered too.
#
# FOUR THINGS, each verified on a live box (2026-08-24) rather than assumed:
#  • IPv4 ONLY. Never ip6tables/fe80::/10 — IPv6 neighbour discovery needs it.
#  • DOCKER-USER sits in FORWARD, so it filters CONTAINER traffic and leaves the
#    host alone — the host's own cloud-init still reaches metadata normally.
#  • REJECT, not DROP: an agent's attempt fails in ~8ms instead of hanging for the
#    full timeout and reading as a network fault.
#  • Docker's embedded DNS is 127.0.0.11, not link-local, so nothing resolves through
#    this rule.
#
# systemd rather than a bare iptables call because DOCKER-USER only exists after
# dockerd starts, and a rule applied once vanishes on the next reboot — a security
# control that silently disables itself is worse than one that was never added.
if command -v iptables &>/dev/null && command -v systemctl &>/dev/null; then
  info "Blocking cloud metadata (169.254.0.0/16) for containers..."
  cat > /etc/systemd/system/damndev-block-linklocal.service <<'UNIT'
[Unit]
Description=Block cloud metadata (169.254.0.0/16) for containers
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
# -C first so a re-run does not stack duplicate rules.
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || iptables -I DOCKER-USER -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  # Never fatal: a host without a DOCKER-USER chain (rootless, nftables-only, an
  # unusual distro) still gets a working install — it just keeps app-layer guarding
  # only. Failing the whole install over defence-in-depth would be the wrong trade.
  systemctl enable --now damndev-block-linklocal 2>/dev/null \
    || warn "Could not apply the metadata block (no DOCKER-USER chain?). The app-layer guard still applies; see CLAUDE.md."
fi

docker compose -f "$INSTALL_DIR/docker-compose.prod.yml" --env-file "$INSTALL_DIR/.env" up -d

echo ""
echo "──────────────────────────────────"
success "damn.dev is live at ${BOLD}https://${DOMAIN}${RESET}"
echo ""
echo "  First login:  create an account at https://${DOMAIN}"
echo "  View logs:    docker compose -f $INSTALL_DIR/docker-compose.prod.yml logs -f"
echo "  Stop:         docker compose -f $INSTALL_DIR/docker-compose.prod.yml down"
if [[ -n "$EE_REGISTRY_USERNAME" ]]; then
  echo ""
  echo "  Enterprise modules: delivered to /app/ee (COMPOSE_PROFILES=ee is persisted in"
  echo "                      $INSTALL_DIR/.env). Apply your licence in Settings → License;"
  echo "                      paid features stay off until an entitlement is present."
fi
echo ""
