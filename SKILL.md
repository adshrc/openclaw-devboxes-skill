---
name: devboxes
description: Manage development environment containers (devboxes) with web-accessible VSCode, VNC, and app routing via Traefik or Cloudflare Tunnels. Use when the user asks to create, start, stop, list, or manage devboxes/dev environments, spin up a development container, set up a coding sandbox, or configure the devbox infrastructure for the first time (onboarding).
---

# Devbox Skill

Devboxes are OpenClaw sandbox containers running a custom image with VSCode Web, noVNC, Chromium (CDP), and up to 5 app ports routed via **Traefik** or **Cloudflare Tunnels**.

OpenClaw manages the full container lifecycle. Containers **self-register** — the entrypoint auto-assigns an ID, writes Traefik routes, and builds `APP_URL_*` env vars. The main agent just spawns and reports URLs.

## File Locations

Resolve paths relative to this SKILL.md's parent directory.

Key files:

- `docker/Dockerfile` + `docker/entrypoint.sh` — devbox image (published as `ghcr.io/adshrc/openclaw-devbox:latest`, no need to build locally)
- `.devbox-counter` — sequential ID counter (created by onboarding, bind-mounted as `/shared/.devbox-counter` inside devbox containers)
- `references/setup-script-guide.md` — conventions for project setup scripts (`.openclaw/setup.sh`)

## Architecture

- **Agent id:** `devbox` (configured in openclaw.json)
- **Sandbox mode:** `all` / `scope: session` — one container per session
- **Image:** `ghcr.io/adshrc/openclaw-devbox:latest` (pulled from GHCR, not built locally)
- **Network:** `traefik` (for Traefik routing) or default Docker network (for Cloudflare Tunnel routing)
- **Browser:** `sandbox.browser.enabled: true`, CDP on port 9222

### Self-Registration (entrypoint)

The container's entrypoint automatically:

1. Reads and increments `/shared/.devbox-counter` → assigns `DEVBOX_ID`
2. Builds `APP_URL_1..5`, `VSCODE_URL`, `NOVNC_URL` from tags + domain + ID
3. Writes `/etc/devbox.env` and `/etc/profile.d/devbox.sh` (available in all shells)
4. Routes based on `ROUTING_MODE`:
   - **`traefik`** (default): Writes Traefik config to `/traefik/devbox-{id}.yml`
   - **`cloudflared`**: Generates cloudflared ingress config, registers DNS CNAME records via CF API, starts `cloudflared tunnel run`

### Bind Mounts (configured in openclaw.json)

| Agent path              | Devbox container path     | Purpose       |
| ----------------------- | ------------------------- | ------------- |
| `.devbox-counter`       | `/shared/.devbox-counter` | ID counter    |
| `/etc/traefik/devboxes` | `/traefik`                | Route configs |

**Important:** Both paths must be writable by the sandbox containers (UID 1000). The counter file needs `chmod 666`, and the Traefik devboxes dir should be owned by `1000:1000` (set up during host provisioning).

### Known Paths

These paths are always the same inside the OpenClaw container:

- **OpenClaw data:** `/home/node/.openclaw`
- **Traefik dynamic config:** `/etc/traefik/devboxes` (must be mounted into the OpenClaw container; only if using Traefik routing)

## Onboarding Flow

**This runs on the MAIN agent, NOT in a sandbox.** The main agent has access to `exec`, `gateway`, and the file system.

When the user asks to set up the devbox skill, do the following:

### Step 1: Gather info and detect paths

Ask the user for:

- **Routing mode**: Traefik or Cloudflare Tunnel?
- **Domain**: with wildcard A-Record pointing to the server (e.g. `*.example.com`)
- **GitHub token** (optional): for cloning private repos inside devboxes

If **Cloudflare Tunnel** is chosen, also ask for:

- **Cloudflare API token**: must have permissions for the zone (DNS edit + Tunnel edit)

### Step 2: Verify prerequisites

#### If routing mode is Traefik:

```bash
# Check that /etc/traefik/devboxes is mounted
ls /etc/traefik/devboxes
```

If `/etc/traefik/devboxes` doesn't exist, tell the user they need to add `-v $HOME/traefik/devboxes:/etc/traefik/devboxes` to their OpenClaw container and restart it.

#### If routing mode is Cloudflare Tunnel:

Validate the CF API token and domain:

```bash
# 1. Verify token is valid
curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" | jq .

# 2. Get zone ID for the domain (extract root domain from the provided domain)
curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${ROOT_DOMAIN}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" | jq .

# 3. Get account ID from the zone response
# account_id = .result[0].account.id
# zone_id = .result[0].id
```

Then create the tunnel:

```bash
# 4. Create a named tunnel
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name": "openclaw-devboxes", "tunnel_secret": "'$(openssl rand -base64 32)'"}' | jq .

# Extract tunnel_id and tunnel_token from the response
# tunnel_id = .result.id
# tunnel_token = .result.token
```

Store the values: `CF_API_TOKEN`, `CF_ZONE_ID`, `CF_ACCOUNT_ID`, `CF_TUNNEL_ID`, `CF_TUNNEL_TOKEN`.

### Step 3: Create counter file

```bash
# Relative to this skill's directory
echo "0" > .devbox-counter
chmod 666 .devbox-counter
```

### Step 4: Configure OpenClaw

First, check the current "agents" config:

```bash
node /app/openclaw.mjs config get agents
```

Then, decice what needs to be adjusted based on the existing config:

### Main Agent

IF there is an agent with `default: true`, note its index and add `subagents.allowAgents` to it:

```bash
node /app/openclaw.mjs config set agents.list[{index}].subagents.allowAgents '["devbox"]' --json
```

then (if needed), set sandbox mode to `off` (since the main agent doesn't need a sandbox):

```bash
node /app/openclaw.mjs config set agents.list[{index}].sandbox.mode "off"
```

ELSE there's no agent with `default: true`, create one at the next index with the necessary structure:

```bash
node /app/openclaw.mjs config set agents.list[{index}] '{
  "id": "main",
  "default": true,
  "subagents": {
    "allowAgents": [
        "devbox"
    ]
  },
  "sandbox": {
    "mode": "off"
  }
}' --json
```

### Devbox Agent

Now add the devbox agent at the next index in agents.list.

Adjust the sandbox and docker config as needed (replace placeholders in curly braces):

```bash
node /app/openclaw.mjs config set agents.list[{index}] '{
    "id": "devbox",
    "name": "Devbox Agent",
    "sandbox": {
      "mode": "all",
      "workspaceAccess": "none",
      "scope": "session",
      "docker": {
        "image": "ghcr.io/adshrc/openclaw-devbox:latest",
        "readOnlyRoot": false,
        "network": "{traefik|cloudflared}",
        "env": {
          "ENABLE_VNC": "true",
          "ENABLE_VSCODE": "true",
          "DEVBOX_DOMAIN": "{domain}",
          "APP_TAG_1": "app1",
          "APP_TAG_2": "app2",
          "APP_TAG_3": "app3",
          "APP_TAG_4": "app4",
          "APP_TAG_5": "app5",
          "GITHUB_TOKEN": "{github_token}",
          "ROUTING_MODE": "{traefik|cloudflared}",
          # Cloudflare Tunnel variables (only needed if using cloudflared routing, exclude otherwise)
          "CF_TUNNEL_TOKEN": "{cf_tunnel_token}",
          "CF_API_TOKEN": "{cf_api_token}",
          "CF_ZONE_ID": "{cf_zone_id}",
          "CF_TUNNEL_ID": "{cf_tunnel_id}",
        },
        "binds": [
          "/home/node/.openclaw/workspace/skills/devboxes/.devbox-counter:/shared/.devbox-counter:rw",
          "/etc/traefik/devboxes:/traefik:rw" # Only needed for Traefik routing mode, exclude otherwise
        ]
      },
      "browser": {
        "enabled": true,
        "cdpPort": 9222
      }
    }
  }
]' --json
```

The Gateway will restart automatically, a restart is not needed!

## Workflow: Spawn a Devbox

### Step 1: Spawn subagent (main agent)

```python
sessions_spawn(
    agentId="devbox",
    label="devbox-{task_name}",
    task="Your task description. GitHub token is in $GITHUB_TOKEN. Env vars (DEVBOX_ID, APP_URL_*, etc.) are in your shell via `source /etc/profile.d/devbox.sh`."
)
```

That's it! The container self-registers. No manual ID assignment or Traefik setup needed.

### Step 2: Report URLs to user (main agent)

Read the counter to know the assigned ID, then report:

```bash
DEVBOX_ID=$(cat .devbox-counter)
```

- VSCode: `https://vscode-{id}.{domain}`
- noVNC: `https://novnc-{id}.{domain}/vnc.html`
- App URLs: `https://{tag}-{id}.{domain}`

### Cleanup

OpenClaw manages container lifecycle — containers are removed when sessions end. Traefik route configs left behind are harmless.

## Environment Variables

### Static (set in openclaw.json sandbox.docker.env)

| Variable          | Example                    | Description                                          |
| ----------------- | -------------------------- | ---------------------------------------------------- |
| `ROUTING_MODE`    | `traefik` or `cloudflared` | Routing backend (default: `traefik`)                 |
| `GITHUB_TOKEN`    | `ghp_...`                  | GitHub PAT for cloning                               |
| `DEVBOX_DOMAIN`   | `oc.example.com`           | Base domain                                          |
| `APP_TAG_1..5`    | `app1`, `app2`, ...        | Route tags                                           |
| `ENABLE_VNC`      | `true`                     | Enable noVNC                                         |
| `ENABLE_VSCODE`   | `true`                     | Enable VSCode Web                                    |
| `CF_TUNNEL_TOKEN` | `eyJ...`                   | Cloudflare tunnel run token (cloudflared only)       |
| `CF_API_TOKEN`    | `abc123`                   | CF API token for DNS registration (cloudflared only) |
| `CF_ZONE_ID`      | `xyz789`                   | CF zone ID for the domain (cloudflared only)         |
| `CF_TUNNEL_ID`    | `uuid`                     | CF tunnel ID for CNAME targets (cloudflared only)    |

### Dynamic (built by entrypoint, available in all shells)

| Variable        | Example                                   | Description                 |
| --------------- | ----------------------------------------- | --------------------------- |
| `DEVBOX_ID`     | `1`                                       | Auto-assigned sequential ID |
| `APP_URL_1..5`  | `https://app1-1.oc.example.com`           | Full URLs per app slot      |
| `APP_PORT_1..5` | `8003..8007`                              | Internal ports              |
| `VSCODE_URL`    | `https://vscode-1.oc.example.com`         | VSCode Web URL              |
| `NOVNC_URL`     | `https://novnc-1.oc.example.com/vnc.html` | noVNC URL                   |

### Ports

| Port      | Service                        |
| --------- | ------------------------------ |
| 8000      | VSCode Web                     |
| 8002      | noVNC                          |
| 9222      | Chrome DevTools Protocol (CDP) |
| 8003-8007 | App slots 1-5                  |

## Browser

The devbox agent has browser access via Chromium CDP (port 9222). The subagent can use the `browser` tool to navigate, screenshot, and interact with apps running inside the container (use `http://localhost:{port}`).

## Project Setup Scripts

Projects can include `.openclaw/setup.sh` that runs inside the devbox. It has access to all env vars (`APP_URL_*`, `APP_PORT_*`, `DEVBOX_ID`, etc.) via `/etc/profile.d/devbox.sh`.

See `references/setup-script-guide.md` for conventions.
