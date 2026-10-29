#!/usr/bin/env bash
set -eu

IMAGE="claude-container:latest"

# Resource ceilings. Not isolation, but they keep a runaway build or a fork
# bomb inside the container from taking the host down with it. A limit above
# the host's physical memory simply never binds, so the default is safe;
# override for a project that needs more.
MEMORY="${CLAUDE_MEMORY:-16g}"
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

# Maven and Gradle keep their local repository in the user's home directory,
# and that home lives inside the container — so without this, every run would
# start with an empty repository and download the world all over again. They
# get their own directory in the state dir, not the host's ~/.m2 and ~/.gradle:
# those sit inside your home directory, which this script deliberately keeps
# out of the container. The cost is one cold start; after that the cache is warm.
#
# One per workspace, at a path that mirrors the workspace path, for the same
# reason the workspace itself is mounted at its host path: a local repository
# is not just a download cache — `mvn install` and Gradle's caches write a
# project's own artifacts into it, and with a shared directory one project's
# snapshots would be resolved by every other.
M2_DIR="${STATE_DIR}/m2${WORKSPACE}"
GRADLE_DIR="${STATE_DIR}/gradle${WORKSPACE}"
mkdir -p "${M2_DIR}" "${GRADLE_DIR}"

# A place of your own in the container that outlives it: the rest of the home
# directory is thrown away with the container, and the workspace belongs to the
# project. Per workspace, like the caches above, so one project's files do not
# show up in another project's container.
ETC_DIR="${STATE_DIR}/etc${WORKSPACE}"
mkdir -p "${ETC_DIR}"

# By default we run Claude Code. Arguments to this script replace that
# command: `claude-container.sh bash` gives you a shell to poke around in, and
# `claude-container.sh claude --resume` runs Claude Code with arguments.
if [ "$#" -eq 0 ]; then
  set -- claude
fi

# A project can prepare the container with a claude-container-init.sh in the
# workspace root — to put a tool on the PATH, say. It is sourced, not run: an
# export in a child process would be gone before the command starts. `exec`
# then replaces the shell, so the command still runs as the container's main
# process. The file comes from the workspace, so it runs with no more rights
# than the command itself.
INIT_SCRIPT="${WORKSPACE}/claude-container-init.sh"
if [ -f "${INIT_SCRIPT}" ]; then
  echo "claude-container: sourcing ${INIT_SCRIPT} in the container"
  set -- bash -c 'source "$0" && exec "$@"' "${INIT_SCRIPT}" "$@"
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
exec docker run --interactive --tty --rm \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit "${PIDS}" \
  --memory "${MEMORY}" \
  --memory-swap "${MEMORY}" \
  --cpus "${CPUS}" \
  --ulimit core=0 \
  --volume "${STATE_DIR}/claude:/home/dev/.claude" \
  --volume "${STATE_DIR}/claude.json:/home/dev/.claude.json" \
  --volume "${M2_DIR}:/home/dev/.m2" \
  --volume "${GRADLE_DIR}:/home/dev/.gradle" \
  --volume "${ETC_DIR}:/home/dev/etc" \
  --volume "${WORKSPACE}:${WORKSPACE}" \
  --workdir "${WORKSPACE}" \
  "${IMAGE}" "$@"
