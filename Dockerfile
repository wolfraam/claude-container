# Pinned versions — every version in this image is declared here and nowhere
# else. Checked and verified against upstream on 2026-09-22.
#
# The base image is pinned twice over: the dated tag says which snapshot it is,
# the digest is what actually gets pulled.
ARG DEBIAN_VERSION=trixie-20260918-slim
ARG DEBIAN_DIGEST=sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

# Debian 13 "Trixie" — current stable release
FROM debian:${DEBIAN_VERSION}@${DEBIAN_DIGEST}

ARG NODE_VERSION=24.21.0
ARG JAVA_MAJOR=21
ARG MAVEN_VERSION=3.9.16
ARG MAVEN_SHA512=831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6
ARG CLAUDE_CODE_VERSION=2.1.280

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
      unzip \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Node.js from the official tarball (Debian's own package lags behind), checksum-verified
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

# JDK from Debian itself: trixie ships OpenJDK 21 as a supported release, so no tarball needed.
# The package lands in an architecture-specific directory, hence the symlink JAVA_HOME points at.
RUN apt-get update \
 && apt-get install -y --no-install-recommends "openjdk-${JAVA_MAJOR}-jdk" \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sfn "/usr/lib/jvm/java-${JAVA_MAJOR}-openjdk-$(dpkg --print-architecture)" /usr/lib/jvm/default-java \
 && javac -version \
 && java -version
ENV JAVA_HOME=/usr/lib/jvm/default-java

# Python from Debian itself (trixie ships 3.13); its version follows the pinned base image.
# Debian marks the system interpreter as externally managed, so `pip install` outside a
# virtualenv is refused — python3-venv is there so projects can create one.
# python-is-python3 makes plain `python` resolve as well.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python-is-python3 \
      python3 \
      python3-pip \
      python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python --version \
 && pip3 --version

# Maven from the upstream release. It is pure Java, so there is nothing
# architecture-specific to pick here; it is fetched upstream rather than from
# Debian because the packaged version lags and pulls in a second JDK. It comes
# from archive.apache.org: the dlcdn mirror only carries the current release, so
# a pinned version stops resolving the moment it is superseded.
#
# Gradle is deliberately not installed: the projects this image is used for ship
# the Gradle wrapper, which fetches its own version into the ~/.gradle cache
# that is mounted into the container.
RUN set -eux; \
    tarball="apache-maven-${MAVEN_VERSION}-bin.tar.gz"; \
    cd /tmp; \
    curl -fsSLO "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/${tarball}"; \
    echo "${MAVEN_SHA512}  ${tarball}" | sha512sum -c -; \
    install -d /opt/maven; \
    tar -xzf "${tarball}" -C /opt/maven --strip-components=1 --no-same-owner; \
    rm -f "${tarball}"; \
    ln -sfn /opt/maven/bin/mvn /usr/local/bin/mvn; \
    mvn --version
ENV MAVEN_HOME=/opt/maven

# Headless GUI stack, so desktop applications (SWT/Swing) can be started and screenshotted
# without a real display. Xvfb brings in x11-xkb-utils, which provides the xkbcomp that the
# X server shells out to at startup — without it the server dies on keyboard initialisation.
# xauth is what xvfb-run uses to set up its cookie. libgtk-3-0t64 and libxtst6 currently
# arrive as openjdk-21-jdk dependencies, but SWT and java.awt.Robot break without them, so
# they are named explicitly instead of relied upon. dbus-x11 only silences SWT's
# SessionManagerDBus warnings. /tmp/.X11-unix is pre-created root-owned to avoid the
# "Owner of /tmp/.X11-unix should be set to root" complaint on every server start.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      dbus-x11 \
      fonts-dejavu-core \
      libgtk-3-0t64 \
      libxtst6 \
      x11-utils \
      xauth \
      xvfb \
 && rm -rf /var/lib/apt/lists/* \
 && install -d -o root -g root -m 1777 /tmp/.X11-unix \
 && command -v Xvfb xvfb-run xkbcomp xdpyinfo

# Claude Code CLI
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
ARG UID
ARG GID
RUN groupadd --gid "${GID}" "${USERNAME}" \
 && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash "${USERNAME}" \
 && install -d -o "${UID}" -g "${GID}" /workspace

USER ${USERNAME}
WORKDIR /workspace

CMD ["claude"]
