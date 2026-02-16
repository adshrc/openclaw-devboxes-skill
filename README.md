# Devboxes Skill for OpenClaw

Spin up a full development environment in seconds — just by asking your agent.

Each devbox is an isolated container with **VSCode in your browser**, a **visual desktop via VNC**, **headless Chromium** for testing, and **up to 5 routable app ports** — all accessible via clean URLs on your domain. No SSH tunnels, no port forwarding, no "works on my machine".

Need to prototype something? Clone a repo and start coding? Debug a frontend on a real browser? Spin up a devbox. It self-registers with Traefik, assigns itself a unique ID, and hands you ready-to-use URLs. When you're done, tear it down. Zero cleanup.

Whether you're working from your laptop, a tablet, or someone else's machine — your full dev environment is one URL away.

## Features

- **Self-registering containers** — auto-assigns ID, configures routing, builds `APP_URL_*` env vars
- **Flexible routing** — choose between Traefik (self-managed) or Cloudflare Tunnels (zero open ports)
- **VSCode Web** — browser-based IDE on port 8000
- **noVNC** — visual desktop access on port 8002
- **Chromium CDP** — headless browser automation on port 9222
- **5 app slots** — routed via Traefik with configurable tags (e.g. `api`, `app`, `dashboard`)
- **Project setup scripts** — `.openclaw/setup.sh` convention for automated repo setup
- **nvm** — Node version management, reads `.nvmrc` automatically

## Architecture

```
+----------------------------------------------------------+
|  Devbox Container (ghcr.io/adshrc/openclaw-devbox:latest)|
|                                                          |
|  +----------+  +----------+  +-------------------+       |
|  |  VSCode  |  |  noVNC   |  |  Chromium (CDP)   |       |
|  |  :8000   |  |  :8002   |  |  :9222            |       |
|  +----------+  +----------+  +-------------------+       |
|                                                          |
|  App 1 :8003   App 2 :8004   App 3 :8005                |
|  App 4 :8006   App 5 :8007                              |
+----------------------------+-----------------------------+
                             |
                      +-----------+
                      |  Traefik  |  <-- routes auto-configured
                      +-----+-----+
                            |
                https://{tag}-{id}.{domain}
```

## Prerequisites

### Routing: Traefik or Cloudflare Tunnels

Devboxes need a way to expose services via URLs. Choose one:

#### Option A: Traefik (self-managed reverse proxy)

Best for: servers with open ports and an existing Traefik setup.

Devbox containers automatically register Traefik routes on startup by writing config files to the Traefik dynamic directory.

> **If you haven't set up Traefik yet**, follow the [OpenClaw + Traefik Setup Guide](https://gist.github.com/adshrc/3cd9e8a714098f414635b7fe1ab5e573#file-openclaw_traefik-md).

Your OpenClaw container needs the Traefik dynamic config directory mounted:

```bash
docker run -d \
  --name openclaw \
  --network traefik \
  --restart unless-stopped \
  -v $HOME/openclaw:/home/node/.openclaw \
  -v $HOME/openclaw/workspace:/home/node/.openclaw/workspace \
  -v $HOME/traefik/dynamic:/etc/traefik/dynamic \
  -e OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN \
  ghcr.io/openclaw/openclaw:latest \
  node openclaw.mjs gateway --allow-unconfigured --bind lan
```

#### Option B: Cloudflare Tunnels (zero open ports)

Best for: environments without a reverse proxy, behind NAT, or where you don't want to expose ports.

Each devbox starts `cloudflared` internally and registers DNS records via the Cloudflare API. All traffic is routed through Cloudflare's network — no open ports or Traefik needed.

Requirements:
- A **Cloudflare account** with a domain managed by Cloudflare
- A **Cloudflare API token** with Zone:DNS:Edit and Account:Tunnel:Edit permissions

The agent handles tunnel creation and configuration during onboarding.

### Wildcard DNS

You need a wildcard DNS record (`*.your-domain.com`) pointing to your server (Traefik mode) or Cloudflare handles DNS automatically (Cloudflare Tunnel mode).

## Quick Start

### 1. Install the skill

Copy the `SKILL.md`, `scripts/`, and `references/` directories into your OpenClaw workspace:

```
$HOME/openclaw/workspace/skills/devboxes/
├── SKILL.md
├── scripts/
│   ├── Dockerfile
│   └── entrypoint.sh
└── references/
    └── setup-script-guide.md
```

### 2. Ask your agent to set it up

Once the skill files are in place, simply ask your OpenClaw agent:

> "Set up the devboxes skill"

The agent will read the skill's onboarding instructions and handle everything:
- Pull the Docker image
- Create the Traefik network (if needed)
- Set up the counter file and permissions
- Configure `openclaw.json` with the devboxes agent
- Ask you for your domain and GitHub token

### 3. Spawn a devbox

After setup, just ask:

> "Spin up a devbox for project X"

The agent spawns a container, waits for self-registration, and returns your URLs.

## Self-Registration

Each container's entrypoint automatically:

1. Reads and increments the shared counter → assigns `DEVBOX_ID`
2. Builds `APP_URL_1..5`, `VSCODE_URL`, `NOVNC_URL` from tags + domain + ID
3. Writes env vars to `/etc/profile.d/devbox.sh` (available in all shells)
4. Writes Traefik config to `/traefik/devbox-{id}.yml`

No manual routing or ID assignment needed.

## Project Setup Scripts

Projects can include `.openclaw/setup.sh` for automated setup inside a devbox:

```bash
#!/bin/bash
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

nvm install && nvm use
npm install

cp template.env .env
sed -i "s/PORT=.*/PORT=$APP_PORT_1/" .env

tmux new -d -s my-server "source /root/.nvm/nvm.sh; nvm use; npm run dev; exec \$SHELL"
echo "Running at $APP_URL_1"
```

See [setup-script-guide.md](references/setup-script-guide.md) for full conventions.

## Environment Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `DEVBOX_ID` | entrypoint | Auto-assigned sequential ID |
| `APP_URL_1..5` | entrypoint | Full external URLs |
| `APP_PORT_1..5` | Dockerfile | Internal ports (8003-8007) |
| `APP_TAG_1..5` | config | Route tags |
| `DEVBOX_DOMAIN` | config | Base domain |
| `ROUTING_MODE` | config | `traefik` (default) or `cloudflared` |
| `GITHUB_TOKEN` | config | GitHub PAT |
| `CF_TUNNEL_TOKEN` | config | Cloudflare tunnel token (cloudflared only) |
| `CF_API_TOKEN` | config | CF API token for DNS (cloudflared only) |
| `CF_ZONE_ID` | config | CF zone ID (cloudflared only) |
| `CF_TUNNEL_ID` | config | CF tunnel ID (cloudflared only) |
| `VSCODE_URL` | entrypoint | VSCode Web URL |
| `NOVNC_URL` | entrypoint | noVNC URL |

## Important Notes

- Sandbox containers run with **all Linux capabilities dropped** (`CapDrop: ALL`). Bind-mounted files/dirs must be world-writable.
- Wildcard DNS (`*.your-domain.com`) must point to your server.
- Traefik must be configured with a file provider watching the dynamic config directory.

## License

MIT
