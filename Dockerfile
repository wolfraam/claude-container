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
      unzip \
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

# Maven and Gradle from the upstream releases. Both are pure Java, so there is
# nothing architecture-specific to pick here; they are fetched upstream rather
# than from Debian because the packaged versions lag and pull in a second JDK.
# Maven comes from archive.apache.org: the dlcdn mirror only carries the current
# release, so a pinned version stops resolving the moment it is superseded.
ARG MAVEN_VERSION=3.9.16
ARG MAVEN_SHA512=831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6
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

# Gradle ships only as a zip, hence unzip among the base packages above.
ARG GRADLE_VERSION=9.7.1
ARG GRADLE_SHA256=acd53f1edaf02f1a8ff99879f8a34b302661a057d9b063ae9e35b552f804d20a
RUN set -eux; \
    zipfile="gradle-${GRADLE_VERSION}-bin.zip"; \
    cd /tmp; \
    curl -fsSLO "https://services.gradle.org/distributions/${zipfile}"; \
    echo "${GRADLE_SHA256}  ${zipfile}" | sha256sum -c -; \
    unzip -q "${zipfile}" -d /opt; \
    mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle; \
    rm -f "${zipfile}"; \
    ln -sfn /opt/gradle/bin/gradle /usr/local/bin/gradle; \
    gradle --version; \
    rm -rf /root/.gradle
ENV GRADLE_HOME=/opt/gradle

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
