# Pinned versions — every version in this image is declared here and nowhere
# else. Checked and verified against upstream on 2026-10-21.
#
# The base image is pinned twice over: the dated tag says which snapshot it is,
# the digest is what actually gets pulled.
ARG DEBIAN_VERSION=trixie-20261020-slim
ARG DEBIAN_DIGEST=sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

# Debian 13 "Trixie" — current stable release
FROM debian:${DEBIAN_VERSION}@${DEBIAN_DIGEST}

ARG NODE_VERSION=24.22.1
ARG JAVA_MAJOR=21
ARG MAVEN_VERSION=3.9.16
ARG MAVEN_SHA512=831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6
ARG HELM_VERSION=3.22.1
# Android: the command-line tools are fetched directly and checked against the
# SHA-256 Google publishes on developer.android.com/studio. Everything else is
# installed by sdkmanager, which checks Google's checksums itself.
#
# Deliberately 22.0, not 23.0: in 23.0 sdkmanager is a wrapper that unpacks the
# new "Android CLI", which checks for updates of itself and uploads usage metrics.
ARG ANDROID_CMDLINE_TOOLS_VERSION=22.0
ARG ANDROID_CMDLINE_TOOLS_BUILD=15859902
ARG ANDROID_CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
ARG ANDROID_PLATFORM_TOOLS_VERSION=37.0.1
ARG ANDROID_PLATFORM=android-37.0
ARG ANDROID_BUILD_TOOLS_VERSION=37.0.0
ARG CLAUDE_CODE_VERSION=2.1.306

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Europe/Amsterdam

# jq, bc and time (the real /usr/bin/time, not the shell keyword) are there for the
# agent's own use: picking apart JSON, doing arithmetic and measuring runs from the shell.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bc \
      ca-certificates \
      curl \
      git \
      jq \
      less \
      procps \
      ripgrep \
      time \
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
# python-is-python3 makes plain `python` resolve as well. pandas comes from Debian too,
# for the same reason: it is the only way to have it on the system interpreter.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python-is-python3 \
      python3 \
      python3-pandas \
      python3-pip \
      python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python --version \
 && pip3 --version \
 && python -c 'import pandas; print("pandas", pandas.__version__)'

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

# Helm from the official release tarball (Debian does not package it), checksum-verified.
# The tarball holds a single static binary, so only that is extracted.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) helm_arch=amd64 ;; \
      arm64) helm_arch=arm64 ;; \
      ppc64el) helm_arch=ppc64le ;; \
      s390x) helm_arch=s390x ;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    tarball="helm-v${HELM_VERSION}-linux-${helm_arch}.tar.gz"; \
    cd /tmp; \
    curl -fsSLO "https://get.helm.sh/${tarball}"; \
    curl -fsSLO "https://get.helm.sh/${tarball}.sha256sum"; \
    sha256sum -c "${tarball}.sha256sum"; \
    tar -xzf "${tarball}" -C /usr/local/bin --strip-components=1 --no-same-owner \
        "linux-${helm_arch}/helm"; \
    rm -f "${tarball}" "${tarball}.sha256sum"; \
    helm version

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

# Android SDK, so Android apps can be built, linted and unit-tested with the Gradle
# wrapper the project ships (the Android Gradle plugin, aapt2 and Kotlin come in
# through Gradle, into the mounted ~/.gradle cache). It sits down here, after the
# user, because it is owned by that user: a project whose compileSdk or build-tools
# differ from the ones preinstalled has the Android Gradle plugin download them
# into the SDK — which only works if the SDK is writable and the licenses accepted.
# Those downloads land in the container, not the image, so they are lost after
# every run; a version a project needs all the time belongs in the ARGs above.
#
# sdkmanager can only install the newest platform-tools, so the version it got is
# checked against the pinned one: when upstream moves, the build fails here
# instead of quietly producing a different image.
#
# Google ships the build tools, platform-tools (adb) and aapt2 for x86_64 Linux
# only, so on any other architecture the SDK is left out altogether. There is no
# emulator: it needs /dev/kvm, which the container does not get.
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools"
RUN set -eux; \
    if [ "$(dpkg --print-architecture)" != amd64 ]; then \
      echo "Android SDK skipped: Google ships it for x86_64 Linux only"; \
      exit 0; \
    fi; \
    zip="commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_BUILD}_latest.zip"; \
    cd /tmp; \
    curl -fsSLO "https://dl.google.com/android/repository/${zip}"; \
    echo "${ANDROID_CMDLINE_TOOLS_SHA256}  ${zip}" | sha256sum -c -; \
    install -d "${ANDROID_HOME}/cmdline-tools"; \
    unzip -q "${zip}" -d "${ANDROID_HOME}/cmdline-tools"; \
    mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"; \
    rm -f "${zip}"; \
    grep -qx "Pkg.Revision=${ANDROID_CMDLINE_TOOLS_VERSION}" \
        "${ANDROID_HOME}/cmdline-tools/latest/source.properties"; \
    export ANDROID_USER_HOME=/tmp/android-user-home; \
    yes | sdkmanager --licenses > /dev/null; \
    sdkmanager --install \
        platform-tools \
        "platforms;${ANDROID_PLATFORM}" \
        "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" > /dev/null; \
    grep -qx "Pkg.Revision=${ANDROID_PLATFORM_TOOLS_VERSION}" \
        "${ANDROID_HOME}/platform-tools/source.properties"; \
    chown -R "${UID}:${GID}" "${ANDROID_HOME}"; \
    sdkmanager --list_installed; \
    adb version; \
    rm -rf "${ANDROID_USER_HOME}"

# ~/.android holds the debug keystore Gradle signs debug builds with, and adb's key.
# The home directory is thrown away after every run, so a fresh keystore would be
# generated each time — and a device refuses to update an app signed with another
# key. ~/etc is mounted per workspace by claude-container.sh and survives a run.
ENV ANDROID_USER_HOME=/home/${USERNAME}/etc/android

USER ${USERNAME}
WORKDIR /workspace

CMD ["claude"]
