#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${HOME}/.agent-bridge"
AB_REF="${AB_REF:-master}"
AB_BASE_URL="${AB_BASE_URL:-https://raw.githubusercontent.com/agent-bridges/ab/${AB_REF}}"
DOWNLOAD_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-only)
      DOWNLOAD_ONLY=1
      shift
      ;;
    --dir)
      TARGET_DIR="${2:?missing target dir}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

mkdir -p "${TARGET_DIR}" "${TARGET_DIR}/workspace" "${TARGET_DIR}/state"
mkdir -p "${TARGET_DIR}/docker/agent-runtime"

fetch() {
  local path="$1"
  local out="$2"
  curl -fsSL "${AB_BASE_URL}/${path}" -o "${out}"
}

fetch ".env.quick-start" "${TARGET_DIR}/.env.quick-start"
fetch "docker-compose.quick-start.yml" "${TARGET_DIR}/docker-compose.quick-start.yml"
fetch "docker/agent-runtime/Dockerfile" "${TARGET_DIR}/docker/agent-runtime/Dockerfile"
fetch "docker/agent-runtime/start-agent-runtime.sh" "${TARGET_DIR}/docker/agent-runtime/start-agent-runtime.sh"

if [[ "${DOWNLOAD_ONLY}" -eq 1 ]]; then
  echo "Downloaded quick-start files to ${TARGET_DIR}"
  exit 0
fi

(
  cd "${TARGET_DIR}"
  docker compose --env-file .env.quick-start -f docker-compose.quick-start.yml up -d
)

cat <<EOF
Agent-Bridge quick-start installed to ${TARGET_DIR}

Front:    http://127.0.0.1:5281
Backend:  http://127.0.0.1:8520
EOF
