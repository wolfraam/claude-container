# Debian 13 "Trixie" — current stable release
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Europe/Amsterdam

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      less \
      procps \
      ripgrep \
      tzdata \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Node.js from the official tarball (Debian's own package lags behind), checksum-verified
ARG NODE_VERSION=24.21.0
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      ppc64el) node_arch=ppc64le ;; \
      s390x) node_arch=s390x ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${tarball}" -C /usr/local --strip-components=1 --no-same-owner \
        --exclude=CHANGELOG.md --exclude=LICENSE --exclude=README.md; \
    rm -f "${tarball}" SHASUMS256.txt; \
    node --version; \
    npm --version

# Claude Code CLI
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

# Non-root user; UID/GID are build args so the container can match the host user
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
RUN groupadd --gid "${GID}" "${USERNAME}" \
 && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash "${USERNAME}" \
 && install -d -o "${UID}" -g "${GID}" /workspace

USER ${USERNAME}
WORKDIR /workspace

CMD ["claude"]
