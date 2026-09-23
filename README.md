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
workspace are simply owned by you (no `chown` needed).

Every version the image installs is pinned in a block at the top of the
`Dockerfile` (base image, Node, JDK, Maven, Claude Code), so a rebuild
produces the same image rather than whatever is current upstream.
Upgrading means editing those `ARG`s. The script uses `--no-cache`, so each
build re-fetches those pinned downloads rather than reusing layers.

## What's in the image

Debian 13 with Node.js (for Claude Code itself) and OpenJDK 21, so
the agent can compile and run Java in the container: `javac`, `java` and the
rest of the JDK tooling are on the `PATH`, and `JAVA_HOME` points at
`/usr/lib/jvm/default-java`. Maven is in the image as well (`/opt/maven`,
with `mvn` on the `PATH` and `MAVEN_HOME` set), from the upstream release and
pinned to a checksum in the `Dockerfile`. Gradle is not installed: the projects
this image is used for ship the Gradle wrapper. A project that ships a wrapper
(`./mvnw`, `./gradlew`) uses its own version, which downloads on first run and
is then kept in the cache described below.

Python 3 comes from Debian (3.13 on trixie, fixed by the pinned base image),
with `python`, `python3`, `pip3` and `venv` available. Debian treats the system
interpreter as externally managed, so install packages into a virtualenv
(`python -m venv .venv`) rather than with a bare `pip install`.

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

## The build directories

The workspace is mounted at its host path, so the container and the host would
otherwise write to the same output directories: two toolchains (a different JDK,
other tool versions, other absolute paths baked into the artifacts) overwriting
each other's output. So those directories are mounted from
`~/.claude-container/build/<workspace path>` — every project keeps its own.
Your own build output stays untouched, and the container never sees it.

Which directories those are follows from the build files in the workspace,
subprojects included — a multi-project build writes output next to every
module's build file:

| file found     | directory mounted next to it        |
| -------------- | ----------------------------------- |
| `gradlew`      | `.gradle` (project-local Gradle cache) |
| `build.gradle` | `build`                             |
| `pom.xml`      | `target`                            |

The list is printed at startup, followed by a five second pause, so you can see
what the container gets before it starts. `.git`, `node_modules` and the output
directories themselves are skipped.

`~/.claude-container/build/<workspace path>` is emptied on every start: output
left by an earlier run comes from a tree that has since changed, and a build
that picks it up is a build you cannot trust. Looking at what the container
built therefore means looking there before the next run.

## Maven and Gradle caches

Maven and the Gradle wrapper keep their local repository under the user's home
directory, and that home lives inside the container, which is thrown away after
every run. So `~/.claude-container/m2/<workspace path>` and
`~/.claude-container/gradle/<workspace path>` are mounted on `~/.m2` and
`~/.gradle` in the container: the local repository, the downloaded wrapper
distributions (the Gradle distribution itself among them) and anything else
these tools cache survive a run, and only the first build pays for the
download.

One pair per workspace, mirroring the workspace path the way the build
directories do. A local repository is not only a download cache: `mvn install`
and Gradle write a project's own artifacts into it, so a shared one would let
one project's snapshots be resolved by every other. The price is that each
project downloads its dependencies once.

Deliberately not your own `~/.m2` and `~/.gradle`: those sit inside your home
directory, which this setup keeps out of the container — a `settings.xml` with
repository credentials among them. The cost is one cold start, and a second
copy of the artifacts you already had on disk. Throwing the caches away is
`rm -rf ~/.claude-container/m2 ~/.claude-container/gradle`, or just one
project's with `rm -rf ~/.claude-container/m2/<workspace path>`.

## Persistent storage

The container's home directory is thrown away after every run, and the
workspace belongs to the project. For anything else that should survive a
restart (notes, scratch data, tool configuration), `~/etc` in the container is
mounted from `~/.claude-container/etc/<workspace path>` on the host. There is
one per workspace, like the caches, so one project's files do not show up in
another project's container. Removing it is
`rm -rf ~/.claude-container/etc/<workspace path>`.

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
