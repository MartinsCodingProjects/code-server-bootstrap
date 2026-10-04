ARG CODE_SERVER_VERSION=4.140.0-ls368
FROM lscr.io/linuxserver/code-server:${CODE_SERVER_VERSION}

ARG NODE_MAJOR=22

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg tmux git \
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
# and exit immediately; point tmux at bash instead.
RUN echo 'set -g default-shell /bin/bash' > /etc/tmux.conf

# Docker CLI + Compose talk to the VM's Docker daemon through the mounted socket.
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose
