#!/usr/bin/env bash
set -eu

IMAGE="claude-container:latest"

# Resource ceilings. Not isolation, but they keep a runaway build or a fork
# bomb inside the container from taking the host down with it. A limit above
# the host's physical memory simply never binds, so the default is safe;
# override for a project that needs more.
MEMORY="${CLAUDE_MEMORY:-8g}"
CPUS="${CLAUDE_CPUS:-4}"
PIDS="${CLAUDE_PIDS:-1024}"

# Claude Code stores its state (login/credentials, settings, history, projects) in
# ~/.claude and ~/.claude.json. Those live here on the host, so they survive a
# container. The container user has the same UID/GID as the host user (see
# build-image.sh), so permissions are correct without chown.
STATE_DIR="$HOME/.claude-container"

mkdir -p "${STATE_DIR}/claude"
# If this path doesn't exist, Docker turns it into a directory, and then
# Claude Code refuses to start — so create it as an empty JSON file up front.
[ -e "${STATE_DIR}/claude.json" ] || echo '{}' > "${STATE_DIR}/claude.json"

# The directory this script is run from is the workspace: we mount that
# read-write into the container, so Claude Code can work on the project.
# Otherwise the container sees nothing of the host filesystem.
#
# The mount path matches the host path. Claude Code keys its per-project
# state to the working directory (~/.claude/projects/<path>, and the
# "projects" key in ~/.claude.json with, among other things, allowedTools and
# the trust dialog). With a fixed /workspace, all projects would end up on a
# single key: sessions and prompt history mixed together, and permissions
# granted in one project immediately applying in another. Using the same
# paths has the side benefit that file:line references from the container
# also work on the host.
WORKSPACE="$(pwd -P)"

# A host path that overlaps a system directory or the container home would
# break the container (or the state mounts above).
case "${WORKSPACE}" in
  /) echo "claude-container: / is not a valid workspace" >&2; exit 1 ;;
  /bin/* | /boot/* | /dev/* | /etc/* | /lib/* | /lib64/* | /proc/* | /root/* \
  | /run/* | /sbin/* | /sys/* | /usr/* | /var/* | /home/dev | /home/dev/*)
      echo "claude-container: ${WORKSPACE} overlaps with the container's filesystem" >&2
      exit 1 ;;
esac

# Your home directory is not a workspace. Mounting it would hand the container
# ~/.ssh, ~/.aws, browser profiles and the state dir above — read-write, in one
# go. The same goes for anything that contains your home directory (/home).
HOME_DIR="$(cd "$HOME" && pwd -P)"
case "${HOME_DIR}" in
  "${WORKSPACE}" | "${WORKSPACE}"/*)
      echo "claude-container: ${WORKSPACE} contains your home directory (${HOME_DIR})" >&2
      echo "claude-container: run this from a project directory instead" >&2
      exit 1 ;;
esac

# The host and the container would otherwise share one build directory: two
# toolchains (a different JDK, different tool versions, different absolute
# paths baked into the artifacts) writing over each other's output. So the
# container gets its own build directories in the state dir, mounted over the
# workspace's — the host's output stays untouched, and invisible to the container.
#
# The path mirrors the workspace path, for the same reason the workspace itself
# is mounted at its host path: every project keeps its own build directory.
BUILD_DIR="${STATE_DIR}/build${WORKSPACE}"

# Wiped on every start: a build directory that survives a run would feed the
# next one stale classes and stale caches from a tree that has since changed.
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Maven and Gradle keep their local repository in the user's home directory,
# and that home lives inside the container — so without this, every run would
# start with an empty repository and download the world all over again. They
# get their own directory in the state dir, not the host's ~/.m2 and ~/.gradle:
# those sit inside your home directory, which this script deliberately keeps
# out of the container. The cost is one cold start; after that the cache is warm.
#
# One per workspace, at the mirrored workspace path BUILD_DIR already uses: a
# local repository is not just a download cache — `mvn install` and Gradle's
# caches write a project's own artifacts into it, and with a shared directory
# one project's snapshots would be resolved by every other. Unlike the build
# directories these survive a run; that is the whole point of a cache.
M2_DIR="${STATE_DIR}/m2${WORKSPACE}"
GRADLE_DIR="${STATE_DIR}/gradle${WORKSPACE}"
mkdir -p "${M2_DIR}" "${GRADLE_DIR}"

# A place of your own in the container that outlives it: the rest of the home
# directory is thrown away with the container, and the workspace belongs to the
# project. Per workspace, like the caches above, so one project's files do not
# show up in another project's container.
ETC_DIR="${STATE_DIR}/etc${WORKSPACE}"
mkdir -p "${ETC_DIR}"

# Which directories get their own mount depends on what the project is. We walk
# the workspace — subprojects included, since a Gradle or Maven multi-project
# build writes output next to every module's build file — and for each marker
# file mount the directory that tool writes into:
#
#   gradlew          -> .gradle   (the project-local Gradle cache)
#   build.gradle     -> build     (Gradle's output directory)
#   pom.xml          -> target    (Maven's output directory)
#
# Pruned: .git and node_modules (nothing in them is a project to build), and the
# output directories themselves — Maven copies the pom into
# target/classes/META-INF/maven/, and matching that copy would mount a build
# directory inside a build directory.
BUILD_VOLUMES=()
BUILD_MOUNTS=()
seen=""
while IFS= read -r -d '' marker; do
  dir="$(dirname "${marker}")"
  case "$(basename "${marker}")" in
    gradlew) out=".gradle" ;;
    build.gradle | build.gradle.kts) out="build" ;;
    pom.xml) out="target" ;;
    *) continue ;;
  esac

  target="${dir}/${out}"
  # A directory can match twice (build.gradle plus build.gradle.kts); Docker
  # refuses a duplicate mount point, so each target is mounted once.
  case "${seen}" in
    *"|${target}|"*) continue ;;
  esac
  seen="${seen}|${target}|"

  # The mirror path: the workspace prefix is what BUILD_DIR already encodes.
  host_dir="${BUILD_DIR}${target#${WORKSPACE}}"
  mkdir -p "${host_dir}"
  BUILD_VOLUMES+=(--volume "${host_dir}:${target}")
  BUILD_MOUNTS+=("${target} -> ${host_dir}")
done < <(find "${WORKSPACE}" \
  \( -name .git -o -name node_modules -o -name build -o -name target \
     -o -name .gradle \) -prune -o \
  -type f \( -name gradlew -o -name build.gradle -o -name build.gradle.kts \
             -o -name pom.xml \) -print0)

# What ends up mounted is worth seeing before the container starts: it is the
# difference between a build that writes to the host and one that does not. The
# pause gives you time to read it (and to Ctrl-C if it looks wrong).
if [ "${#BUILD_MOUNTS[@]}" -eq 0 ]; then
  echo "claude-container: no build files found, no build directories mounted"
else
  echo "claude-container: build directories mounted into ${BUILD_DIR}:"
  for mount in "${BUILD_MOUNTS[@]}"; do
    echo "  ${mount}"
  done
fi
sleep 2

# By default we run Claude Code. Arguments to this script replace that
# command: `claude-container.sh bash` gives you a shell to poke around in, and
# `claude-container.sh claude --resume` runs Claude Code with arguments.
if [ "$#" -eq 0 ]; then
  set -- claude
fi

# On the docker run flags below:
#
#   --cap-drop=ALL          Docker hands a container ~14 capabilities by default
#                           (CHOWN, DAC_OVERRIDE, SETUID, SETGID, NET_RAW, ...).
#                           Claude Code, node, git and ripgrep need none of them
#                           as a non-root user. Casualties: ping/traceroute
#                           (NET_RAW) and su/sudo (SETUID/SETGID).
#   --security-opt ...      Blocks privilege escalation through the setuid
#                           binaries debian-slim still ships (mount, su, chfn).
#   --tmpfs /tmp            Keeps scratch files in RAM instead of on the host
#                           disk, and caps how much of it there can be. The
#                           'exec' is load-bearing: Docker mounts every tmpfs
#                           noexec unless told otherwise, and node, npm, Maven
#                           and Gradle unpack native libraries into /tmp and map
#                           them executable (jansi, netty, jna, ...).
#   ${BUILD_VOLUMES...}    The build mounts collected above. The [@]+ form keeps
#                           set -u from tripping over an empty array on a
#                           project that has no build files at all.
exec docker run --interactive --tty --rm \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit "${PIDS}" \
  --memory "${MEMORY}" \
  --memory-swap "${MEMORY}" \
  --cpus "${CPUS}" \
  --ulimit core=0 \
  --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777 \
  --volume "${STATE_DIR}/claude:/home/dev/.claude" \
  --volume "${STATE_DIR}/claude.json:/home/dev/.claude.json" \
  --volume "${M2_DIR}:/home/dev/.m2" \
  --volume "${GRADLE_DIR}:/home/dev/.gradle" \
  --volume "${ETC_DIR}:/home/dev/etc" \
  --volume "${WORKSPACE}:${WORKSPACE}" \
  ${BUILD_VOLUMES[@]+"${BUILD_VOLUMES[@]}"} \
  --workdir "${WORKSPACE}" \
  "${IMAGE}" "$@"
