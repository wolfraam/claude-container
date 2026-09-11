#!/usr/bin/env bash
set -eu

IMAGE="claude-container:latest"

# Claude Code bewaart zijn state (login/credentials, settings, history, projects) in
# ~/.claude en ~/.claude.json. Die staan hier op de host, zodat ze een container
# overleven. De container-user heeft dezelfde UID/GID als de host-user (zie
# build-image.sh), dus de rechten kloppen zonder chown.
STATE_DIR="$HOME/.claude-container"

mkdir -p "${STATE_DIR}/claude"
# Als dit pad niet bestaat maakt Docker er een directory van, en dan weigert
# Claude Code te starten — dus vooraf als leeg JSON-bestand aanmaken.
[ -e "${STATE_DIR}/claude.json" ] || echo '{}' > "${STATE_DIR}/claude.json"

# De directory waaruit dit script gedraaid wordt is de workspace: die mounten we
# read-write op /workspace (de WORKDIR van het image), zodat Claude Code met het
# project kan werken. Verder ziet de container niets van het host-filesystem.
WORKSPACE="$(pwd -P)"

# Standaard draaien we Claude Code, maar met CLAUDE_CMD kan een ander commando in de
# container gedraaid worden (bijv. CLAUDE_CMD=bash om even rond te kijken). Eventuele
# argumenten aan dit script gaan door naar dat commando.
CMD="${CLAUDE_CMD:-claude}"

exec docker run --interactive --tty --rm \
  --volume "${STATE_DIR}/claude:/home/dev/.claude" \
  --volume "${STATE_DIR}/claude.json:/home/dev/.claude.json" \
  --volume "${WORKSPACE}:/workspace" \
  --workdir /workspace \
  "${IMAGE}" "${CMD}" "$@"
