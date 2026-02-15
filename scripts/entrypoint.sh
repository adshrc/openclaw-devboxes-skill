#!/bin/bash
set -e

# Source nvm
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Ports
: "${VSCODE_PORT:=8000}"
: "${NOVNC_PORT:=8002}"
: "${CDP_PORT:=9222}"
: "${APP_PORT_1:=8003}"
: "${APP_PORT_2:=8004}"
: "${APP_PORT_3:=8005}"
: "${APP_PORT_4:=8006}"
: "${APP_PORT_5:=8007}"

# Tags & domain
: "${DEVBOX_DOMAIN:=oc.servier.bar}"
: "${APP_TAG_1:=api}"
: "${APP_TAG_2:=kiosk}"
: "${APP_TAG_3:=console}"
: "${APP_TAG_4:=app4}"
: "${APP_TAG_5:=app5}"

########################################
# Devbox ID assignment
########################################
COUNTER_FILE="/shared/.devbox-counter"
if [ -f "$COUNTER_FILE" ]; then
    export DEVBOX_ID=$(( $(cat "$COUNTER_FILE") + 1 ))
else
    export DEVBOX_ID=1
fi
echo "$DEVBOX_ID" > "$COUNTER_FILE"
echo "[devbox] Assigned ID: $DEVBOX_ID"

########################################
# Build APP_URL_* env vars
########################################
for i in 1 2 3 4 5; do
    tag_var="APP_TAG_$i"
    export "APP_URL_$i=https://${!tag_var}-${DEVBOX_ID}.${DEVBOX_DOMAIN}"
done
export VSCODE_URL="https://vscode-${DEVBOX_ID}.${DEVBOX_DOMAIN}"
export NOVNC_URL="https://novnc-${DEVBOX_ID}.${DEVBOX_DOMAIN}/vnc.html"

# Write env vars to /etc/devbox.env and /etc/profile.d/ so they're available everywhere
cat > /etc/devbox.env << EOF
export DEVBOX_ID=$DEVBOX_ID
export DEVBOX_DOMAIN=$DEVBOX_DOMAIN
export VSCODE_URL=$VSCODE_URL
export NOVNC_URL=$NOVNC_URL
$(for i in 1 2 3 4 5; do
    tag_var="APP_TAG_$i"
    port_var="APP_PORT_$i"
    echo "export APP_TAG_$i=${!tag_var}"
    echo "export APP_PORT_$i=${!port_var}"
    echo "export APP_URL_$i=$(eval echo \$APP_URL_$i)"
done)
EOF

# Make env vars available in all new shells
cp /etc/devbox.env /etc/profile.d/devbox.sh
echo ". /etc/devbox.env" >> /root/.bashrc

########################################
# Traefik self-registration
########################################
TRAEFIK_DIR="/traefik"
if [ -d "$TRAEFIK_DIR" ]; then
    CONTAINER_NAME=$(hostname)
    CONFIG_FILE="${TRAEFIK_DIR}/devbox-${DEVBOX_ID}.yml"

    python3 -c "
import sys
devbox_id = '${DEVBOX_ID}'
container = '${CONTAINER_NAME}'
domain = '${DEVBOX_DOMAIN}'

services = {'vscode': ${VSCODE_PORT}, 'novnc': ${NOVNC_PORT}}
tags = ['${APP_TAG_1}','${APP_TAG_2}','${APP_TAG_3}','${APP_TAG_4}','${APP_TAG_5}']
ports = [${APP_PORT_1},${APP_PORT_2},${APP_PORT_3},${APP_PORT_4},${APP_PORT_5}]
for tag, port in zip(tags, ports):
    services[tag] = port

lines = ['http:', '  routers:']
for name in services:
    svc = f'{name}-{devbox_id}'
    lines += [
        f'    {svc}:',
        f'      rule: \"Host(\`{svc}.{domain}\`)\"',
        f'      service: {svc}',
        f'      entryPoints:',
        f'        - web',
    ]
lines.append('  services:')
for name, port in services.items():
    svc = f'{name}-{devbox_id}'
    lines += [
        f'    {svc}:',
        f'      loadBalancer:',
        f'        servers:',
        f'          - url: \"http://{container}:{port}\"',
    ]
with open('${CONFIG_FILE}', 'w') as f:
    f.write('\n'.join(lines) + '\n')
"
    echo "[devbox] Traefik config written: $CONFIG_FILE"
else
    echo "[devbox] WARNING: /traefik not mounted, skipping self-registration"
fi

echo "[devbox] Starting services..."

########################################
# Browser + CDP (sandbox-browser pattern)
########################################
# Xvfb virtual display
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 1

# Chromium with CDP on internal port
CHROME_CDP_INTERNAL=$((CDP_PORT + 1))
chromium \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="${CHROME_CDP_INTERNAL}" \
    --user-data-dir=/tmp/.chrome \
    --no-first-run \
    --no-default-browser-check \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --disable-features=TranslateUI \
    --disable-breakpad \
    --disable-crash-reporter \
    --metrics-recording-only \
    --no-sandbox \
    about:blank &

# Wait for CDP to be ready
for _ in $(seq 1 50); do
    if curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_INTERNAL}/json/version" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# socat: expose CDP on 0.0.0.0 for OpenClaw browser tool
socat TCP-LISTEN:"${CDP_PORT}",fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:"${CHROME_CDP_INTERNAL}" &
echo "[devbox] CDP ready on port ${CDP_PORT}"

########################################
# VNC + noVNC
########################################
if [ "${ENABLE_VNC:-false}" = "true" ]; then
    VNC_PORT=5900
    x11vnc -display :1 -rfbport "${VNC_PORT}" -shared -forever -nopw -localhost &
    websockify --web=/usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" > /dev/null 2>&1 &
    echo "[devbox] noVNC ready on port ${NOVNC_PORT}"
fi

########################################
# VSCode Web
########################################
if [ "${ENABLE_VSCODE:-false}" = "true" ]; then
    "${OPENVSCODE_SERVER_ROOT}/bin/openvscode-server" \
        --host 0.0.0.0 \
        --port "${VSCODE_PORT}" \
        --without-connection-token \
        --default-folder /workspace \
        > /dev/null 2>&1 &
    echo "[devbox] VSCode ready on port ${VSCODE_PORT}"
fi

########################################
# Summary
########################################
echo "[devbox] Ports:"
echo "  VSCode:  ${VSCODE_PORT}"
echo "  noVNC:   ${NOVNC_PORT}"
echo "  CDP:     ${CDP_PORT}"
for i in 1 2 3 4 5; do
    port_var="APP_PORT_$i"
    url_var="APP_URL_$i"
    tag_var="APP_TAG_$i"
    echo "  App $i (${!tag_var:-?}): port=${!port_var} url=${!url_var:-not set}"
done
echo "[devbox] Ready."

exec "$@"
