#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PTY_DIR="${REPO_ROOT}/ab-pty"
ARTIFACT_DIR="${PTY_DIR}/.artifacts"
ARTIFACT_PATH="${ARTIFACT_DIR}/ab-pty-linux-amd64-glibc"

require_docker

if [[ ! -d "${PTY_DIR}" ]]; then
  echo "Missing PTY repo: ${PTY_DIR}" >&2
  exit 1
fi

mkdir -p "${ARTIFACT_DIR}"

docker run --rm \
  -v "${PTY_DIR}:/src" \
  -w /src \
  golang:1.23-bookworm \
  bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends build-essential >/dev/null
    version="$(tr -d '"'"'[:space:]'"'"' < VERSION)"
    CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
      go build \
      -trimpath \
      -ldflags "-s -w -X main.Version=${version}" \
      -o .artifacts/ab-pty-linux-amd64-glibc \
      .
  '

chmod +x "${ARTIFACT_PATH}"
echo "Built ${ARTIFACT_PATH}"
file "${ARTIFACT_PATH}"
"${ARTIFACT_PATH}" version
