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

# JDK 21 from Debian itself: trixie ships OpenJDK 21 as a supported release, so no tarball needed.
# The package lands in an architecture-specific directory, hence the symlink JAVA_HOME points at.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-21-jdk \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sfn "/usr/lib/jvm/java-21-openjdk-$(dpkg --print-architecture)" /usr/lib/jvm/default-java \
 && javac -version \
 && java -version
ENV JAVA_HOME=/usr/lib/jvm/default-java

# Claude Code CLI
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

# Managed settings are read from /etc/claude-code and outrank user and project settings,
# so Remote Control stays off no matter what ends up in the mounted workspace or home dir.
# The directory is created up front: a COPY that creates it applies --chmod to it as well,
# which would leave it non-traversable for the non-root user.
RUN install -d -o root -g root -m 0755 /etc/claude-code
COPY --chown=root:root --chmod=644 managed-settings.json /etc/claude-code/managed-settings.json

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
