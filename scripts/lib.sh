#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FILTERED_ARGS=()

require_nonempty_envs() {
  local missing=0
  local name value

  for name in "$@"; do
    value="${!name:-}"
    if [[ -z "${value}" ]]; then
      echo "Missing required env var in .env: ${name}" >&2
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required" >&2
    exit 1
  fi
}

ensure_env() {
  if [[ ! -f "${REPO_ROOT}/.env" ]]; then
    cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
    sed -i "s|^AB_WORKSPACE_PATH=__REPO_ROOT__|AB_WORKSPACE_PATH=${REPO_ROOT}|" "${REPO_ROOT}/.env"
    echo "Created .env from .env.example"
  fi
}

load_env() {
  ensure_env
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
}

ensure_state() {
  mkdir -p \
    "${REPO_ROOT}/state/back" \
    "${REPO_ROOT}/state/pty/dot-claude" \
    "${REPO_ROOT}/state/demo/agent/data"
  touch "${REPO_ROOT}/state/pty/claude.json"
}

configure_test_data_mode() {
  local include_demo="${AB_INCLUDE_TEST_DATA:-1}"
  FILTERED_ARGS=()

  for arg in "$@"; do
    case "${arg}" in
      --skip-test-data)
        include_demo=0
        ;;
      *)
        FILTERED_ARGS+=("${arg}")
        ;;
    esac
  done

  export AB_INCLUDE_TEST_DATA="${include_demo}"
}

should_include_test_data() {
  case "${AB_INCLUDE_TEST_DATA:-1}" in
    0|false|False|FALSE|no|No|NO)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

resolve_path() {
  local raw="$1"
  if [[ "${raw}" = /* ]]; then
    realpath -m "${raw}"
  else
    realpath -m "${REPO_ROOT}/${raw}"
  fi
}

validate_runtime_paths() {
  load_env

  require_nonempty_envs \
    AB_BACK_IMAGE \
    AB_FRONT_IMAGE \
    AB_WORKSPACE_PATH \
    AB_BACK_STATE_DIR \
    AB_PTY_STATE_DIR \
    AB_PTY_CLAUDE_DIR \
    AB_PTY_CLAUDE_JSON_PATH \
    AB_BACKEND_PORT \
    AB_FRONT_PORT \
    AB_JWT_SECRET_PATH \
    AB_DEFAULT_USERNAME \
    AB_DEFAULT_PASSWORD \
    AB_PTY_ALLOWED_ORIGINS \
    AB_DEMO_AGENT_NAME \
    AB_DEMO_AGENT_IP \
    AB_DEMO_AGENT_STATE_DIR \
    AB_DEMO_AGENT_JWT_SECRET_PATH

  local workspace_path
  workspace_path="$(resolve_path "${AB_WORKSPACE_PATH}")"

  local missing=0
  if [[ ! -d "${workspace_path}" ]]; then
    echo "Missing workspace path: ${workspace_path}" >&2
    missing=1
  fi

  if [[ "${AB_WORKSPACE_PATH}" != /* ]]; then
    echo "AB_WORKSPACE_PATH must be absolute in .env: ${AB_WORKSPACE_PATH}" >&2
    missing=1
  fi

  if [[ ! -f "${AB_JWT_SECRET_PATH}" ]]; then
    echo "Missing JWT secret: ${AB_JWT_SECRET_PATH}" >&2
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

validate_dev_paths() {
  load_env

  local back_path front_path pty_path
  back_path="$(resolve_path "${AB_BACK_PATH}")"
  front_path="$(resolve_path "${AB_FRONT_PATH}")"
  pty_path="$(resolve_path "${AB_PTY_PATH}")"

  local missing=0
  validate_runtime_paths

  for path in "${back_path}" "${front_path}" "${pty_path}"; do
    if [[ ! -d "${path}" ]]; then
      echo "Missing path: ${path}" >&2
      missing=1
    fi
  done

  for path in "${back_path}" "${front_path}" "${pty_path}"; do
    if [[ ! -d "${path}/.git" ]]; then
      echo "Missing child repo metadata: ${path}/.git" >&2
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

run_compose() {
  load_env
  ensure_state
  (
    cd "${REPO_ROOT}"
    local compose_args=(-f docker-compose.yml)
    if should_include_test_data; then
      compose_args+=(-f docker-compose.demo.yml)
    fi
    docker compose "${compose_args[@]}" "$@"
  )
}

run_compose_dev() {
  load_env
  ensure_state
  (
    cd "${REPO_ROOT}"
    local compose_args=(-f docker-compose.yml)
    if should_include_test_data; then
      compose_args+=(-f docker-compose.demo.yml)
    fi
    compose_args+=(-f docker-compose.dev.yml)
    if should_include_test_data; then
      compose_args+=(-f docker-compose.dev-demo.yml)
    fi
    docker compose "${compose_args[@]}" "$@"
  )
}

print_endpoints() {
  load_env
  cat <<EOF
Backend: http://127.0.0.1:${AB_BACKEND_PORT}
Front:   http://127.0.0.1:${AB_FRONT_PORT}
PTY:     internal only (docker network, service name: pty:8421)
Demo agent: enabled by default via docker-compose.demo.yml, disable with --skip-test-data
EOF
}
