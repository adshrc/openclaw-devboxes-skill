---
name: devboxes
description: Manage development environment containers (devboxes) with web-accessible VSCode, VNC, and app routing via Traefik. Use when the user asks to create, start, stop, list, or manage devboxes/dev environments, spin up a development container, set up a coding sandbox, or configure the devbox infrastructure for the first time (onboarding).
---

# Devbox Skill

Devboxes are OpenClaw sandbox containers running a custom image with VSCode Web, noVNC, Chromium (CDP), and up to 5 app ports routed via Traefik.

OpenClaw manages the full container lifecycle. Containers **self-register** — the entrypoint auto-assigns an ID, writes Traefik routes, and builds `APP_URL_*` env vars. The main agent just spawns and reports URLs.

## File Locations

All scripts live in the skill's `scripts/` directory. Resolve paths relative to this SKILL.md's parent directory.

Key files:
- `scripts/Dockerfile` + `scripts/entrypoint.sh` — devbox image (published as `ghcr.io/adshrc/openclaw-devbox:latest`)
- `scripts/.devbox-counter` — sequential ID counter (created by onboarding, bind-mounted as `/shared/.devbox-counter` inside devbox containers)

## Architecture

- **Agent id:** `devbox` (configured in openclaw.json)
- **Sandbox mode:** `all` / `scope: session` — one container per session
- **Image:** `ghcr.io/adshrc/openclaw-devbox:latest` (pulled from GHCR, not built locally)
- **Network:** `traefik` (for routing and git access)
- **Browser:** `sandbox.browser.enabled: true`, CDP on port 9222

### Self-Registration (entrypoint)

The container's entrypoint automatically:
1. Reads and increments `/shared/.devbox-counter` → assigns `DEVBOX_ID`
2. Builds `APP_URL_1..5`, `VSCODE_URL`, `NOVNC_URL` from tags + domain + ID
3. Writes `/etc/devbox.env` and `/etc/profile.d/devbox.sh` (available in all shells)
4. Writes Traefik config to `/traefik/devbox-{id}.yml` (Traefik auto-picks it up)

### Bind Mounts (configured in openclaw.json)

| Agent path | Devbox container path | Purpose |
|-----------|----------------------|---------|
| `scripts/.devbox-counter` | `/shared/.devbox-counter` | ID counter |
| `/etc/traefik/dynamic` | `/traefik` | Route configs |

**Important:** Both paths must be world-writable (`chmod 666` / `chmod 777`) because sandbox containers run with `CapDrop: ALL`.

### Known Paths

These paths are always the same inside the OpenClaw container:
- **OpenClaw data:** `/home/node/.openclaw`
- **Traefik dynamic config:** `/etc/traefik/dynamic` (must be mounted into the OpenClaw container)

If `/etc/traefik/dynamic` is not available, it means the OpenClaw container doesn't have it mounted — the user needs to add `-v $HOME/traefik/dynamic:/etc/traefik/dynamic` to their OpenClaw `docker run` command and restart.

## Onboarding Flow

**This runs on the MAIN agent, NOT in a sandbox.** The main agent has access to `exec`, `gateway`, and the file system.

When the user asks to set up the devbox skill, do the following:

### Step 1: Gather info and detect paths

Ask the user for:
- **Domain**: with wildcard DNS (`*.domain`) pointing to the server (e.g. `oc.example.com`)
- **GitHub token** (optional): for cloning private repos inside devboxes

### Step 2: Verify prerequisites

```bash
# Docker access
docker info > /dev/null 2>&1

# Traefik network exists
docker network ls | grep traefik

# Check that /etc/traefik/dynamic is mounted
ls /etc/traefik/dynamic

# Pull the image (NOT build)
docker pull ghcr.io/adshrc/openclaw-devbox:latest
```

If Traefik network doesn't exist: `docker network create traefik`

If `/etc/traefik/dynamic` doesn't exist, tell the user they need to add `-v $HOME/traefik/dynamic:/etc/traefik/dynamic` to their OpenClaw container and restart it.

### Step 3: Create counter file

```bash
# Relative to this skill's directory
echo "0" > scripts/.devbox-counter
chmod 666 scripts/.devbox-counter
```

### Step 4: Ensure Traefik dynamic dir is writable

```bash
chmod 777 /etc/traefik/dynamic
```

### Step 5: Configure OpenClaw

Use `gateway config.patch` to add the devbox agent. This is the **correct** way — do NOT tell the user to manually edit openclaw.json.

The patch should add a devbox agent to the agents list:

```json
{
  "agents": {
    "list": [
      {
        "id": "devbox",
        "name": "Devbox",
        "sandbox": {
          "mode": "all",
          "workspaceAccess": "none",
          "scope": "session",
          "browser": {
            "enabled": true,
            "cdpPort": 9222
          },
          "docker": {
            "image": "ghcr.io/adshrc/openclaw-devbox:latest",
            "readOnlyRoot": false,
            "network": "traefik",
            "env": {
              "DEVBOX_DOMAIN": "{domain}",
              "APP_TAG_1": "api",
              "APP_TAG_2": "app",
              "APP_TAG_3": "dashboard",
              "APP_TAG_4": "app4",
              "APP_TAG_5": "app5",
              "ENABLE_VNC": "true",
              "ENABLE_VSCODE": "true",
              "GITHUB_TOKEN": "{github_token}"
            },
            "binds": [
              "/home/node/.openclaw/workspace/skills/devbox/scripts/.devbox-counter:/shared/.devbox-counter:rw",
              "/etc/traefik/dynamic:/traefik:rw"
            ]
          }
        }
      }
    ]
  }
}
```

**Important:** When patching, you need to read the current config first (`gateway config.get`), then merge the devbox agent into the existing `agents.list` array, and also ensure the main agent has `subagents: { allowAgents: ["devbox"] }`. Then apply with `gateway config.apply`.

### Step 6: Test

After the gateway restarts, spawn a test devbox to verify self-registration and URLs work.

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
DEVBOX_ID=$(cat scripts/.devbox-counter)
```

- VSCode: `https://vscode-{id}.{domain}`
- noVNC: `https://novnc-{id}.{domain}/vnc.html`
- App URLs: `https://{tag}-{id}.{domain}`

### Cleanup

OpenClaw manages container lifecycle — containers are removed when sessions end. Traefik route configs left behind are harmless (Traefik returns 502/404 for dead backends).

## Environment Variables

### Static (set in openclaw.json sandbox.docker.env)

| Variable | Example | Description |
|----------|---------|-------------|
| `GITHUB_TOKEN` | `ghp_...` | GitHub PAT for cloning |
| `DEVBOX_DOMAIN` | `oc.example.com` | Base domain |
| `APP_TAG_1..5` | `api`, `app`, ... | Route tags |
| `ENABLE_VNC` | `true` | Enable noVNC |
| `ENABLE_VSCODE` | `true` | Enable VSCode Web |

### Dynamic (built by entrypoint, available in all shells)

| Variable | Example | Description |
|----------|---------|-------------|
| `DEVBOX_ID` | `1` | Auto-assigned sequential ID |
| `APP_URL_1..5` | `https://api-1.oc.example.com` | Full URLs per app slot |
| `APP_PORT_1..5` | `8003..8007` | Internal ports |
| `VSCODE_URL` | `https://vscode-1.oc.example.com` | VSCode Web URL |
| `NOVNC_URL` | `https://novnc-1.oc.example.com/vnc.html` | noVNC URL |

### Ports

| Port | Service |
|------|---------|
| 8000 | VSCode Web |
| 8002 | noVNC |
| 9222 | Chrome DevTools Protocol (CDP) |
| 8003-8007 | App slots 1-5 |

## Browser

The devbox agent has browser access via Chromium CDP (port 9222). The subagent can use the `browser` tool to navigate, screenshot, and interact with apps running inside the container (use `http://localhost:{port}`).

## Project Setup Scripts

Projects can include `.openclaw/setup.sh` that runs inside the devbox. It has access to all env vars (`APP_URL_*`, `APP_PORT_*`, `DEVBOX_ID`, etc.) via `/etc/profile.d/devbox.sh`.

See `references/setup-script-guide.md` for conventions.
