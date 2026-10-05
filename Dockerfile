ARG CODE_SERVER_VERSION=4.140.0-ls368
ARG DOCKER_CLI_VERSION=29.8.2
ARG UV_VERSION=0.12.23

FROM docker:${DOCKER_CLI_VERSION}-cli AS dockercli

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM lscr.io/linuxserver/code-server:${CODE_SERVER_VERSION}

ARG NODE_MAJOR=22

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg tmux git python3 python3-venv python3-pip \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs gh \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# The abc user's login shell is /bin/false, which tmux would use for new windows
# and exit immediately; point tmux at bash instead. `terminal-w` attaches to (or
# creates) the persistent "work" session; it is an alias, not an automatic
# attach, so each terminal tab stays independent unless you run it.
RUN echo 'set -g default-shell /bin/bash' > /etc/tmux.conf \
 && echo "alias terminal-w='tmux new -As work'" >> /etc/bash.bashrc \
 && echo 'unset VIRTUAL_ENV  # the base image points it at an empty /lsiopy; uv warns about it' >> /etc/bash.bashrc

# Workaround for a code-server cookie bug with per-port hostnames (see the patch file).
COPY patches/code-server-cookie-domain.js /tmp/code-server-cookie-domain.js
RUN node /tmp/code-server-cookie-domain.js && rm /tmp/code-server-cookie-domain.js

# uv: Python package, virtualenv and interpreter manager. It downloads prebuilt Python
# versions on demand (into /config, which persists), so no compiler is needed.
COPY --from=uv /uv /uvx /usr/local/bin/

# Docker CLI + Compose talk to the VM's Docker daemon through the mounted socket.
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
