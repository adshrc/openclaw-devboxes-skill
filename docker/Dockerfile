# syntax=docker/dockerfile:1.7
# OpenClaw Devbox — Dev environment with browser, VSCode, VNC, Node
# Base: sandbox-browser pattern + dev tools

ARG DEBIAN_VERSION=bookworm-slim
ARG NODE_VERSION=24.13.0
ARG VSCODE_PORT=8000
ARG NOVNC_PORT=8002
ARG CDP_PORT=9222
ARG APP_PORT_1=8003
ARG APP_PORT_2=8004
ARG APP_PORT_3=8005
ARG APP_PORT_4=8006
ARG APP_PORT_5=8007

####################################################################################
# Stage 1: Base system + browser (mirrors sandbox-browser)
####################################################################################
FROM debian:${DEBIAN_VERSION} AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV SHELL=/bin/bash

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # Core
        bash ca-certificates curl wget git jq python3 \
        # Browser + VNC (sandbox-browser stack)
        chromium \
        fonts-liberation fonts-noto-color-emoji \
        xvfb x11vnc novnc websockify socat \
        # Build tools
        build-essential pkg-config \
        # System utils
        coreutils util-linux procps findutils grep sed gawk tmux \
        # Networking
        apt-transport-https gnupg lsb-release openssh-client \
        # Locale
        locales \
        # Misc
        tree unzip zip xz-utils; \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Install cloudflared
RUN set -eux; \
    arch=$(dpkg --print-architecture); \
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" \
        -O /tmp/cloudflared.deb; \
    dpkg -i /tmp/cloudflared.deb; \
    rm /tmp/cloudflared.deb; \
    cloudflared --version

####################################################################################
# Stage 2: Dev tools (ripgrep, fd, GitHub CLI)
####################################################################################
FROM base AS dev-tools

RUN set -eux; \
    mkdir -p -m 755 /etc/apt/keyrings; \
    wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gh ripgrep fd-find imagemagick; \
    ln -sf /usr/bin/fdfind /usr/bin/fd; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

####################################################################################
# Stage 3: nvm + Node
####################################################################################
FROM dev-tools AS node-env

ARG NODE_VERSION
ENV NVM_DIR=/root/.nvm

RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    nvm use default && \
    node --version && \
    npm --version"

RUN bash -c "source $NVM_DIR/nvm.sh && \
    ln -sf \$(which node) /usr/local/bin/node && \
    ln -sf \$(which npm) /usr/local/bin/npm && \
    ln -sf \$(which npx) /usr/local/bin/npx"

RUN echo 'export NVM_DIR="/root/.nvm"' >> /root/.bashrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' >> /root/.bashrc

####################################################################################
# Stage 4: VSCode Web (openvscode-server)
####################################################################################
FROM node-env AS vscode

ARG OPENVSCODE_RELEASE=openvscode-server-v1.98.2
ARG OPENVSCODE_ORG=gitpod-io

ENV OPENVSCODE_SERVER_ROOT=/root/.openvscode-server
ENV EDITOR=code VISUAL=code GIT_EDITOR="code --wait"

RUN set -eux; \
    arch=$(uname -m); \
    case "${arch}" in \
        x86_64)  arch="x64" ;; \
        aarch64) arch="arm64" ;; \
        armv7l)  arch="armhf" ;; \
    esac; \
    wget -q "https://github.com/${OPENVSCODE_ORG}/openvscode-server/releases/download/${OPENVSCODE_RELEASE}/${OPENVSCODE_RELEASE}-linux-${arch}.tar.gz"; \
    tar -xzf "${OPENVSCODE_RELEASE}-linux-${arch}.tar.gz"; \
    mv "${OPENVSCODE_RELEASE}-linux-${arch}" "${OPENVSCODE_SERVER_ROOT}"; \
    cp "${OPENVSCODE_SERVER_ROOT}/bin/remote-cli/openvscode-server" \
       "${OPENVSCODE_SERVER_ROOT}/bin/remote-cli/code"; \
    rm -f "${OPENVSCODE_RELEASE}-linux-${arch}.tar.gz"

# Install essential VSCode extensions
RUN ${OPENVSCODE_SERVER_ROOT}/bin/openvscode-server --install-extension vscode.git 2>/dev/null || true; \
    ${OPENVSCODE_SERVER_ROOT}/bin/openvscode-server --install-extension vscode.git-base 2>/dev/null || true

####################################################################################
# Stage 5: Final
####################################################################################
FROM vscode AS final

RUN mkdir -p /workspace

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Re-declare ARGs
ARG VSCODE_PORT=8000
ARG NOVNC_PORT=8002
ARG CDP_PORT=9222
ARG APP_PORT_1=8003
ARG APP_PORT_2=8004
ARG APP_PORT_3=8005
ARG APP_PORT_4=8006
ARG APP_PORT_5=8007

ENV DISPLAY=:1 \
    CHROME_BIN=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    VSCODE_PORT=${VSCODE_PORT} \
    NOVNC_PORT=${NOVNC_PORT} \
    CDP_PORT=${CDP_PORT} \
    APP_PORT_1=${APP_PORT_1} \
    APP_PORT_2=${APP_PORT_2} \
    APP_PORT_3=${APP_PORT_3} \
    APP_PORT_4=${APP_PORT_4} \
    APP_PORT_5=${APP_PORT_5} \
    ENABLE_VNC=true \
    ENABLE_VSCODE=true

EXPOSE ${VSCODE_PORT} ${NOVNC_PORT} ${CDP_PORT} ${APP_PORT_1} ${APP_PORT_2} ${APP_PORT_3} ${APP_PORT_4} ${APP_PORT_5}

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
