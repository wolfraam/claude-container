#!/usr/bin/env bash
set -eu

IMAGE="claude-container:latest"
NETWORK="claude-net"

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

# By default we run Claude Code, but CLAUDE_CMD lets you run a different
# command in the container (e.g. CLAUDE_CMD=bash to poke around). Any
# arguments to this script are passed through to that command.
CMD="${CLAUDE_CMD:-claude}"

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
#                           disk, and caps how much of it there can be. No
#                           noexec: node and npm do run things out of /tmp.
exec docker run --interactive --tty --rm \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit "${PIDS}" \
  --memory "${MEMORY}" \
  --memory-swap "${MEMORY}" \
  --cpus "${CPUS}" \
  --ulimit core=0 \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g,mode=1777 \
  --volume "${STATE_DIR}/claude:/home/dev/.claude" \
  --volume "${STATE_DIR}/claude.json:/home/dev/.claude.json" \
  --volume "${WORKSPACE}:${WORKSPACE}" \
  --workdir "${WORKSPACE}" \
  "${IMAGE}" "${CMD}" "$@"
