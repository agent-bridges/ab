#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/stack.sh <up|down|ps|logs> [--mode prod|dev|quick-start] [--skip-test-data] [extra docker compose args...]

Modes:
  prod         Published-image stack driven by .env
  dev          Bind-mount developer stack driven by .env
  quick-start  One-command demo stack driven by .env.quick-start

Examples:
  scripts/stack.sh up --mode prod
  scripts/stack.sh up --mode prod --skip-test-data
  scripts/stack.sh up --mode dev
  scripts/stack.sh up --mode quick-start
  docker compose --env-file .env.quick-start -f docker-compose.quick-start.yml up -d
EOF
}

COMMAND="${1:-}"
if [[ -z "${COMMAND}" ]]; then
  usage
  exit 1
fi
shift

MODE="prod"
FILTERED_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      FILTERED_ARGS+=("$1")
      shift
      ;;
  esac
done

case "${COMMAND}" in
  up|down|ps|logs)
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    usage
    exit 1
    ;;
esac

case "${MODE}" in
  prod)
    require_docker
    configure_test_data_mode "${FILTERED_ARGS[@]}"
    ensure_env
    ensure_state
    validate_runtime_paths

    if [[ "${COMMAND}" == "up" ]] && should_include_test_data; then
      "${SCRIPT_DIR}/seed-demo.sh" prepare
    fi

    case "${COMMAND}" in
      up) run_compose up -d "${FILTERED_ARGS[@]}" ;;
      down) run_compose down "${FILTERED_ARGS[@]}" ;;
      ps) run_compose ps "${FILTERED_ARGS[@]}" ;;
      logs) run_compose logs --tail=200 "${FILTERED_ARGS[@]}" ;;
    esac

    if [[ "${COMMAND}" == "up" ]]; then
      if should_include_test_data; then
        "${SCRIPT_DIR}/seed-demo.sh" upsert
      else
        "${SCRIPT_DIR}/seed-demo.sh" remove
      fi
      print_endpoints
    fi
    ;;

  dev)
    require_docker
    configure_test_data_mode "${FILTERED_ARGS[@]}"
    ensure_env
    ensure_state
    validate_dev_paths

    if [[ "${COMMAND}" == "up" ]] && should_include_test_data; then
      "${SCRIPT_DIR}/seed-demo.sh" prepare
    fi

    case "${COMMAND}" in
      up) run_compose_dev up -d --build "${FILTERED_ARGS[@]}" ;;
      down) run_compose_dev down "${FILTERED_ARGS[@]}" ;;
      ps) run_compose_dev ps "${FILTERED_ARGS[@]}" ;;
      logs) run_compose_dev logs --tail=200 "${FILTERED_ARGS[@]}" ;;
    esac

    if [[ "${COMMAND}" == "up" ]]; then
      if should_include_test_data; then
        "${SCRIPT_DIR}/seed-demo.sh" upsert
      else
        "${SCRIPT_DIR}/seed-demo.sh" remove
      fi
      print_endpoints
    fi
    ;;

  quick-start)
    if printf '%s\n' "${FILTERED_ARGS[@]}" | rg -qx -- '--skip-test-data' >/dev/null 2>&1; then
      echo "--skip-test-data is not supported in quick-start mode" >&2
      exit 1
    fi
    require_docker
    (
      cd "${REPO_ROOT}"
      case "${COMMAND}" in
        up) docker compose --env-file .env.quick-start -f docker-compose.quick-start.yml up -d "${FILTERED_ARGS[@]}" ;;
        down) docker compose --env-file .env.quick-start -f docker-compose.quick-start.yml down "${FILTERED_ARGS[@]}" ;;
        ps) docker compose --env-file .env.quick-start -f docker-compose.quick-start.yml ps "${FILTERED_ARGS[@]}" ;;
        logs) docker compose --env-file .env.quick-start -f docker-compose.quick-start.yml logs --tail=200 "${FILTERED_ARGS[@]}" ;;
      esac
    )
    if [[ "${COMMAND}" == "up" ]]; then
      cat <<'EOF'
Backend: http://127.0.0.1:8520
Front:   http://127.0.0.1:5281
Quick-start demo agent: enabled by default
EOF
    fi
    ;;

  *)
    echo "Unknown mode: ${MODE}" >&2
    usage
    exit 1
    ;;
esac
