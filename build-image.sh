#!/usr/bin/env bash
set -ex

args=(
  --build-arg "UID=$(id -u)"
  --build-arg "GID=$(id -g)"
)

docker build --no-cache "${args[@]}" -t "claude-container:latest" .
