# claude-container

Claude Code in a Docker container, with a non-root user that has the same
UID/GID as the host user. State (login, settings, history) is kept on the
host in `~/.claude-container`, so it survives a container.

## Requirements

- Docker
- A Linux host (the scripts use `id -u`/`id -g` and bind mounts)

## Installing

Build the image with `build-image.sh`:

```bash
./build-image.sh
```

This builds the image `claude-container:latest` with `--build-arg UID/GID`
matching the current host user, so files the container creates in the
workspace are simply owned by you (no `chown` needed). The script uses
`--no-cache`, so every build fetches the latest Claude Code version and
Node tarball again.

## Running

Go to the directory of the project you want to work on and run:

```bash
/path/to/claude-container/claude-container.sh
```

This mounts the current working directory read-write into the container at
the same path, and starts `claude` in it. Extra arguments are passed
through to that command:

```bash
claude-container.sh --help
```

Want to run something other than `claude` (for example to poke around in
the container), set `CLAUDE_CMD`:

```bash
CLAUDE_CMD=bash claude-container.sh
```

The script refuses to start if the working directory coincides with a
system directory or with the container user's home — that would break the
state mounts or the container itself. It also refuses to start in your own
home directory (or anything above it): mounting that would hand the
container `~/.ssh`, `~/.aws`, browser profiles and its own state directory
in one go.

Resource ceilings can be overridden per run; the defaults are 8g of memory,
4 CPUs and 1024 processes:

```bash
CLAUDE_MEMORY=16g CLAUDE_CPUS=8 claude-container.sh
```

## Isolation

The container runs as a non-root user with all capabilities dropped
(`--cap-drop=ALL`), `no-new-privileges` set, `/tmp` on a size-capped tmpfs,
and limits on memory, CPU and process count. 

Two things the container does have, by design: the workspace is mounted
read-write, so anything Claude Code runs can change every file in the
project you started it from, and `~/.claude-container/claude` holds your
login token.

## Being able to run from any directory

To be able to call `claude-container.sh` from anywhere without typing the
full path, create a symlink in a directory that's on your `PATH`, for
example `/usr/local/bin`:

```bash
sudo ln -s /path/to/claude-container/claude-container.sh /usr/local/bin/claude-container
```

Replace `/path/to/claude-container` with the absolute path to this
repository. After that, you can simply do, from any project:

```bash
cd /path/to/another/project
claude-container
```

Because it's a symlink (not a copy), you automatically pick up changes to
`claude-container.sh` as soon as you commit them in this repo. Remember to
rebuild the image with `./build-image.sh` after every change to
`Dockerfile` or `build-image.sh`.
