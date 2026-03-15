# damn.dev

Self-hosted workspace OS. You and your AI agents, working as a team.

Your data stays on your machine. Agents have memory, personality, skills, and relationships with each other. You stay in control — nothing happens without your approval. The longer you run it, the smarter it gets.

---

## Install

### npm (macOS / Linux)
Node.js 18+ required.

```bash
curl https://raw.githubusercontent.com/LethoDeter/damn-dev-install/main/install-local.sh | bash
```

### Docker (macOS / Linux)
Docker Desktop or Engine 24+ required.

```bash
curl https://raw.githubusercontent.com/LethoDeter/damn-dev-install/main/install-docker.sh | bash
```

### VPS (self-hosted, public domain)
Docker + Caddy. Brings TLS, a real domain, and persistent uptime.

```bash
git clone https://github.com/LethoDeter/damn-dev
cd damn-dev
bash scripts/install.sh
```

---

## What you get

- **Guided onboarding** — connects OpenClaw, picks your models, spawns your first agent. No config files.
- **Agent channels** — DMs, group conversations, topic channels. Agents collaborate autonomously when you ask them to.
- **Approval engine** — agents propose, you decide. Shell commands, file edits, trust changes — nothing runs silently.
- **COO agent** — describe what you need in plain language. COO designs the team, you approve.
- **Agent identity** — every agent has a SOUL, MEMORY, KNOWLEDGE, REFLEXION, and HEARTBEAT. They remember. They evolve.
- **Heartbeat scheduling** — agents run background tasks on a timer: reviewing memory, doing research, staying sharp.
- **Skills** — give agents tools. Shell access, APIs, custom scripts — with per-binary allowlists and working dir sandboxing.
- **Full control** — per-agent model routing, sandbox mode, shell allowlists, mount management. Sane defaults, full depth when you want it.

---

## Update

Re-run your install script. Secrets are preserved. An in-app banner appears when a new version is available.

---

## Stop

**npm:** `pkill -F ~/.damn-dev/damn-dev.pid && pkill -F ~/.damn-dev/openclaw.pid`

**Docker / VPS:** `docker compose -f ~/.damn-dev/docker-compose.local.yml down`

---

## This repo

| File | Purpose |
|------|---------|
| `install-local.sh` | npm install |
| `install-docker.sh` | Docker install |
| `version.json` | Polled by damn.dev for update notifications |

To ship a release: bump `version.json` → `{ "version": "x.y.z" }`.

Source: [github.com/LethoDeter/damn-dev](https://github.com/LethoDeter/damn-dev)
