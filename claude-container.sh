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
# read-write in de container, zodat Claude Code met het project kan werken. Verder
# ziet de container niets van het host-filesystem.
#
# Het mountpad is gelijk aan het host-pad. Claude Code sleutelt zijn per-project
# state aan de working directory (~/.claude/projects/<pad>, en de "projects"-key in
# ~/.claude.json met o.a. allowedTools en het trust-dialog). Met een vast /workspace
# zouden álle projecten op één key uitkomen: sessies en prompt-history door elkaar,
# en permissies die je in het ene project toestaat gelden meteen in het andere.
# Dezelfde paden hebben als bijvangst dat file:line-verwijzingen uit de container
# ook op de host kloppen.
WORKSPACE="$(pwd -P)"

# Een host-pad dat over een systeemdirectory of over de container-home heen mount
# zou de container (of de state-mounts hierboven) slopen.
case "${WORKSPACE}" in
  /) echo "claude-container: / is geen geldige workspace" >&2; exit 1 ;;
  /bin/* | /boot/* | /dev/* | /etc/* | /lib/* | /lib64/* | /proc/* | /root/* \
  | /run/* | /sbin/* | /sys/* | /usr/* | /var/* | /home/dev | /home/dev/*)
      echo "claude-container: ${WORKSPACE} overlapt met het filesystem van de container" >&2
      exit 1 ;;
esac

# Standaard draaien we Claude Code, maar met CLAUDE_CMD kan een ander commando in de
# container gedraaid worden (bijv. CLAUDE_CMD=bash om even rond te kijken). Eventuele
# argumenten aan dit script gaan door naar dat commando.
CMD="${CLAUDE_CMD:-claude}"

exec docker run --interactive --tty --rm \
  --volume "${STATE_DIR}/claude:/home/dev/.claude" \
  --volume "${STATE_DIR}/claude.json:/home/dev/.claude.json" \
  --volume "${WORKSPACE}:${WORKSPACE}" \
  --workdir "${WORKSPACE}" \
  "${IMAGE}" "${CMD}" "$@"
