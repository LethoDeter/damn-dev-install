#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${BOLD}[damn.dev]${RESET} $*"; }
success() { echo -e "${GREEN}[damn.dev]${RESET} $*"; }
die()     { echo -e "${RED}[damn.dev] ERROR:${RESET} $*" >&2; exit 1; }

# Resolve the bundled damndev OpenClaw plugin dir inside the globally-installed
# @damn-dev/cli. pnpm's global layout changes across versions and is NOT
# discoverable by hardcoding `$(pnpm root -g)/node_modules/...`: pnpm 10 returns
# `.../global/5/node_modules` (package under `.pnpm/...`), while pnpm 11 returns
# `.../global/v11` (no node_modules suffix) with the real modules under a HASHED
# subdir (`.../global/v11/<hash>/node_modules/...`). So ask pnpm directly for the
# installed package path (layout-independent), then fall back to globbing every
# known global-root shape, then to the `damn-dev` bin. Prints the path, or fails.
resolve_damndev_plugin() {
  local groot bin real pkg c
  # Authoritative + version-independent: pnpm prints the resolved package dir.
  pkg="$(pnpm ls -g --parseable --depth 0 2>/dev/null | grep -E '/@damn-dev/cli$' | head -1)"
  [[ -n "$pkg" && -d "$pkg/runtime/plugins/damndev" ]] && { printf '%s' "$pkg/runtime/plugins/damndev"; return 0; }
  # Fallback: try known global-root layouts. The unquoted glob covers pnpm 11's
  # hashed subdir (`$groot/*/node_modules/@damn-dev/cli`); no match leaves the
  # literal path, which the `-d` test rejects safely.
  groot="$(pnpm root -g 2>/dev/null || true)"
  for c in "${groot:+$groot/@damn-dev/cli}" "${groot:+$groot/node_modules/@damn-dev/cli}" ${groot:+$groot/*/node_modules/@damn-dev/cli}; do
    [[ -n "$c" && -d "$c/runtime/plugins/damndev" ]] && { printf '%s' "$c/runtime/plugins/damndev"; return 0; }
  done
  # Last resort: resolve through the damn-dev bin (a pnpm shim on pnpm installs,
  # so this rarely resolves the package — kept as belt-and-suspenders).
  bin="$(command -v damn-dev 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then
    real="$(node -e 'process.stdout.write(require("fs").realpathSync(process.argv[1]))' "$bin" 2>/dev/null || true)"
    if [[ -n "$real" ]]; then
      pkg="$(dirname "$(dirname "$real")")"   # <pkg>/bin/damn-dev.js → <pkg>
      [[ -d "$pkg/runtime/plugins/damndev" ]] && { printf '%s' "$pkg/runtime/plugins/damndev"; return 0; }
    fi
  fi
  return 1
}

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

check_node() { ensure_node_22; }

# Require Node 22+ because better-auth (and other modern deps) are ESM-only;
# CommonJS require() of ESM is only supported unflagged on Node 22+.
#
# The FLOOR IS NOW 22.22.3, not bare "major >= 22". OpenClaw 2026.7.1 raised its
# own engines to ">=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0" and it does not warn
# — the CLI REFUSES to start. A host on e.g. 22.18.0 passed the old check, then
# `npm install -g openclaw` below installed a version that would not run, and
# every agent stopped. Only this path is exposed: every docker path bundles its
# own Node inside the image. Mirrors the pre-flight in updateOpenClaw().
#
# Node 23 is deliberately excluded — it is outside OpenClaw's supported range.
#
# Tiered upgrade flow: same as install-docker.sh.
#   1. Node already satisfies the range → continue
#   2. Homebrew present → offer brew install node@22 (Y/n)
#   3. No brew → point at damn.dev DMG desktop app + nodejs.org fallback
ensure_node_22() {
  if command -v node &>/dev/null && \
     node -e "const v=process.versions.node.split('.').map(Number);
              const ok = (v[0]===22 && (v[1]>22 || (v[1]===22 && v[2]>=3)))
                      || (v[0]===24 && (v[1]>15 || (v[1]===15 && v[2]>=0)))
                      ||  v[0]>=25;
              process.exit(ok ? 0 : 1)" 2>/dev/null; then
    info "Node.js $(node --version) detected."
    return 0
  fi

  local current
  current=$(command -v node &>/dev/null && node --version 2>/dev/null || echo "(not installed)")
  echo ""
  info "Node.js 22.22.3+ (or 24.15+) is required — damn.dev needs ESM support, and OpenClaw 2026.7.1+ refuses to start on anything older."
  info "Currently: $current"
  echo ""

  if command -v brew &>/dev/null; then
    local reply=""
    if [[ -r /dev/tty ]]; then
      read -r -p "Install and activate Node 22 via Homebrew now? [Y/n] " reply </dev/tty
    else
      reply="Y"
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
      die "Node was installed but $(node --version) is still the default. Open a new terminal and re-run: curl -fsSL ${INSTALL_BASE_URL:-https://install.damn.dev}/npm | bash"
    fi
    die "Upgrade declined. Install Node 22+ and re-run. Tip: brew install node@22 && brew link --overwrite --force node@22"
  fi

  echo -e "${BOLD}Homebrew not found.${RESET} Two options:"
  echo ""
  echo -e "${BOLD}1. Download the damn.dev desktop app${RESET} (recommended if you don't want to deal with Node):"
  echo "   It bundles its own Node 22 — zero setup. Drag, drop, run."
  echo "   → https://damn.dev  (download section)"
  echo "   → https://github.com/LethoDeter/damn-dev-install/releases/latest  (direct binaries)"
  echo ""
  echo -e "${BOLD}2. Install Node 22 LTS yourself${RESET} (then re-run this installer):"
  echo "   → https://nodejs.org/en/download  (select the macOS .pkg installer)"
  echo "   After install, open a new terminal and re-run:"
  echo "     curl -fsSL ${INSTALL_BASE_URL}/install-local.sh | bash"
  echo ""
  command -v open     &>/dev/null && open     "https://damn.dev" 2>/dev/null || true
  command -v xdg-open &>/dev/null && xdg-open "https://damn.dev" 2>/dev/null || true
  die "Pick one of the above to continue."
}

# ── pnpm (required to install @damn-dev/cli) ─────────────────────────────────
#
# @damn-dev/cli depends on camoufox-js (browser-builtin), which pulls in the
# native `impit` library. impit ships a `preinstall: npx only-allow pnpm` guard
# that HARD-FAILS any npm-based install (the user sees `npm error code 127 …
# only-allow … pnpm` and the install aborts). The guard passes under pnpm, so we
# install the CLI with pnpm. corepack (bundled with Node 22) provides pnpm with
# no separate global install; we fall back to `npm install -g pnpm` if corepack
# is unavailable (pnpm itself has no only-allow guard, so that path is safe).
persist_pnpm_path() {
  local marker="# damn.dev installer — pnpm global bin on PATH"
  local rc
  case "${SHELL:-}" in
    *zsh)  rc="$HOME/.zshrc" ;;
    *bash) rc="$HOME/.bashrc" ;;
    *)     rc="$HOME/.profile" ;;
  esac
  if [[ -f "$rc" ]] && grep -qF "$marker" "$rc" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    printf 'export PNPM_HOME="%s"\n' "$PNPM_HOME"
    printf 'case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac\n'
  } >> "$rc"
  info "Added pnpm to PATH in ${rc/#$HOME/~} (takes effect in new terminals)."
}

ensure_pnpm() {
  local had_pnpm=""
  if command -v pnpm &>/dev/null; then had_pnpm="yes"; fi

  if [[ -z "$had_pnpm" ]]; then
    info "Activating pnpm via corepack..."
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    if command -v corepack &>/dev/null; then
      corepack enable pnpm >/dev/null 2>&1 || true
      corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
      hash -r
    fi
    if ! command -v pnpm &>/dev/null; then
      info "corepack unavailable — installing pnpm via npm..."
      npm install -g pnpm >/dev/null 2>&1 || die "Could not install pnpm. Run: npm install -g pnpm — then re-run this installer."
      hash -r
    fi
  fi
  command -v pnpm &>/dev/null || die "pnpm could not be activated. Install it manually (npm install -g pnpm) and re-run."

  # pnpm links global binaries into its global bin dir, which is NOT on PATH by
  # default (npm's global prefix is — that's why the old npm path got `damn-dev`
  # for free). Make the dir deterministic, add it to PATH for this run, and
  # persist it so `damn-dev` resolves in future shells.
  if [[ -n "$had_pnpm" ]]; then
    local gbin; gbin="$(pnpm bin -g 2>/dev/null || true)"
    if [[ -n "$gbin" ]]; then
      case ":$PATH:" in *":$gbin:"*) ;; *) export PATH="$gbin:$PATH" ;; esac
    fi
  else
    export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
    mkdir -p "$PNPM_HOME"
    case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac
    pnpm config set global-bin-dir "$PNPM_HOME" >/dev/null 2>&1 || true
    persist_pnpm_path
  fi
  hash -r
  success "pnpm $(pnpm --version) ready."
}

# ── Package installation (CLI first so plugin is available for OpenClaw) ──────

install_npm_packages() {
  ensure_pnpm
  # `pnpm add -g` is idempotent — installs on first run, updates thereafter.
  # pnpm 10+ blocks dependency build scripts by default: interactively it
  # prompts, non-interactively (curl | bash — no TTY) it SILENTLY SKIPS them.
  # Skipped builds = no better-sqlite3 native binary + no `prisma generate`
  # postinstall = `damn-dev start` won't boot. So we explicitly allow the
  # build-script deps we ship. Keep this list in lockstep with install-docker.sh,
  # the backend installCliLatest(), and .github/workflows/cli-install-guard.yml
  # (CI fails if a shipped build-script dep is missing here).
  info "Installing @damn-dev/cli (via pnpm)..."
  pnpm add -g @damn-dev/cli \
    --allow-build=@damn-dev/cli \
    --allow-build=better-sqlite3 \
    --allow-build=impit \
    --allow-build=node-pty \
    --allow-build=sharp \
    --allow-build=@whiskeysockets/baileys \
    --allow-build=protobufjs \
    --allow-build=prisma \
    --allow-build=@prisma/client \
    --allow-build=@prisma/engines
  command -v damn-dev &>/dev/null || die "@damn-dev/cli installed but 'damn-dev' is not on PATH. Open a new terminal and re-run, or add pnpm's global bin to PATH."

  # OpenClaw runs natively on the npm path. It has no only-allow guard and
  # doesn't pull impit, so a plain npm global install is fine here.
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
  # Copy the bundled damndev plugin from the @damn-dev/cli package. Ask the CLI
  # where it is — `damn-dev plugin-path` resolves it from the package's own
  # location, independent of pnpm's global layout (which changes across versions
  # and broke the grep-based locator on pnpm 11). Fall back to the layout-sniffing
  # resolver for older CLIs that predate `plugin-path`.
  local plugin_src
  plugin_src="$(damn-dev plugin-path 2>/dev/null || true)"
  if [[ -z "$plugin_src" || ! -d "$plugin_src" ]]; then
    plugin_src="$(resolve_damndev_plugin || true)"
  fi
  if [[ -z "$plugin_src" || ! -d "$plugin_src" ]]; then
    die "damndev plugin not found under the @damn-dev/cli install (pnpm root -g: $(pnpm root -g 2>/dev/null)). The install may be incomplete — re-run: curl -fsSL https://install.damn.dev/npm | bash"
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
  "channels": {
    "damndev": { "healthMonitor": { "enabled": true, "interval": 300 } }
  },
  "agents": {
    "defaults": {
      "sandbox": { "mode": "off" }
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
      "admin-http-rpc": { "enabled": true },
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

  # Migrate the config before starting. OpenClaw >= 2026.6.11 hard-REJECTS a
  # pre-6.11 config (agents.defaults: Invalid input) and refuses to start, so an
  # existing install cannot come back up on a newer openclaw without this. Does
  # the whole migration in one pass (embeddedPi -> embeddedAgent, openai-codex/*
  # -> openai/* + agentRuntime, cron + per-agent auth into SQLite) and keeps
  # openclaw.json.bak. Best-effort: a doctor failure must not block the start —
  # the gateway's own strict validation is the honest gate, and the health wait
  # below is what actually reports failure.
  info "Migrating OpenClaw config (doctor --fix)..."
  if ! openclaw doctor --fix >> "$DAMN_DEV_DIR/openclaw.log" 2>&1; then
    info "openclaw doctor --fix exited non-zero — continuing; see $DAMN_DEV_DIR/openclaw.log"
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
PORT=${PORT}
ENV_EOF
}

# Mirrors install-docker.sh's check_port. Without it the installer wrote a config
# for :PORT, the backend failed to bind because a neighbour app already held it,
# and the only symptom was the health wait timing out with no reason given.
# Runs AFTER the stop below so re-running the installer isn't blocked by our own
# still-running backend.
check_port() {
  if lsof -iTCP:"${PORT}" -sTCP:LISTEN &>/dev/null 2>&1; then
    die "Port ${PORT} is already in use by another process. Re-run with a different port: PORT=3002 curl ${INSTALL_BASE_URL}/install-local.sh | bash"
  fi
}

start_damn_dev() {
  # damn-dev CLI manages its own pidfile (writes to ~/.damn-dev/damn-dev.pid).
  # Re-running start when already up is refused by the CLI, so stop first.
  damn-dev stop >/dev/null 2>&1 || true
  check_port
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
