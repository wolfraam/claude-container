# claude-container

Claude Code in een Docker-container, met een non-root user die dezelfde UID/GID
heeft als de host-user. State (login, settings, history) blijft bewaard op de
host in `~/.claude-container`, zodat die een container overleeft.

## Vereisten

- Docker
- Een Linux-host (de scripts gebruiken `id -u`/`id -g` en bind-mounts)

## Installeren

Bouw de image met `build-image.sh`:

```bash
./build-image.sh
```

Dit bouwt de image `claude-container:latest` met `--build-arg UID/GID` gelijk
aan de huidige host-user, zodat bestanden die de container in de workspace
aanmaakt gewoon van jou zijn (geen `chown` nodig). Het script gebruikt
`--no-cache`, dus elke build haalt de laatste Claude Code-versie en
Node-tarball opnieuw op.

## Runnen

Ga naar de directory van het project waar je aan wilt werken en start:

```bash
/pad/naar/claude-container/claude-container.sh
```

Dit mount de huidige working directory read-write in de container op
hetzelfde pad, en start daarin `claude`. Extra argumenten worden
doorgegeven aan dat commando:

```bash
claude-container.sh --help
```

Wil je iets anders draaien dan `claude` (bijvoorbeeld even rondkijken in de
container), zet dan `CLAUDE_CMD`:

```bash
CLAUDE_CMD=bash claude-container.sh
```

Het script weigert te starten als de working directory samenvalt met een
systeemdirectory of met de home van de container-user — dat zou de state-mounts
of de container zelf slopen.

## Vanuit elke directory kunnen draaien

Om `claude-container.sh` overal te kunnen aanroepen zonder het volledige pad te
typen, zet je een symlink in een directory die in je `PATH` staat, bijvoorbeeld
`/usr/local/bin`:

```bash
sudo ln -s /pad/naar/claude-container/claude-container.sh /usr/local/bin/claude-container
```

Vervang `/pad/naar/claude-container` door het absolute pad naar deze
repository. Daarna kun je gewoon vanuit elk project:

```bash
cd /pad/naar/een/ander/project
claude-container
```

Omdat het een symlink is (geen kopie), pak je automatisch wijzigingen aan
`claude-container.sh` mee zodra je die commit in deze repo. Vergeet niet om na
elke wijziging aan `Dockerfile` of `build-image.sh` de image opnieuw te
bouwen met `./build-image.sh`.
