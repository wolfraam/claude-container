#!/usr/bin/env bash
set -eu

IMAGE="claude-container:latest"

# Claude Code bewaart zijn state (login/credentials, settings, history, projects) in
# ~/.claude en ~/.claude.json. Die staan hier op de host, zodat ze een container
# overleven. De container-user heeft dezelfde UID/GID als de host-user (zie
# build-image.sh), dus de rechten kloppen zonder chown.
STATE_DIR="${CLAUDE_CONTAINER_STATE:-$HOME/.claude-container}"

mkdir -p "${STATE_DIR}/claude"
# Als dit pad niet bestaat maakt Docker er een directory van, en dan weigert
# Claude Code te starten — dus vooraf als leeg JSON-bestand aanmaken.
[ -e "${STATE_DIR}/claude.json" ] || echo '{}' > "${STATE_DIR}/claude.json"

exec docker run --interactive --tty --rm \
  --volume "${STATE_DIR}/claude:/home/dev/.claude" \
  --volume "${STATE_DIR}/claude.json:/home/dev/.claude.json" \
  "${IMAGE}" claude "$@"
