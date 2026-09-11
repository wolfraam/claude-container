#!/usr/bin/env bash
set -ex

IMAGE="claude-container"
TAG="latest"

args=(
  --build-arg "UID=$(id -u)"
  --build-arg "GID=$(id -g)"
)

docker build --no-cache "${args[@]}" -t "${IMAGE}:${TAG}" .
