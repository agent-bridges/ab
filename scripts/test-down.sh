#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TEST_PROJECT_NAME=""
TEST_BACKEND_PORT=""
TEST_FRONT_PORT=""
TEST_AGENT1_PORT=""
TEST_AGENT2_PORT=""

run_test_compose_down() {
  load_env
  (
    cd "${REPO_ROOT}"
    export COMPOSE_PROJECT_NAME="${TEST_PROJECT_NAME}"
    export AB_BACKEND_PORT="${TEST_BACKEND_PORT}"
    export AB_FRONT_PORT="${TEST_FRONT_PORT}"
    export AB_BACK_STATE_DIR="./state/test/back"
    export AB_PTY_STATE_DIR="./state/test/pty"
    export AB_PTY_CLAUDE_DIR="./state/test/pty/dot-claude"
    export AB_PTY_CLAUDE_JSON_PATH="./state/test/pty/claude.json"
    export AB_JWT_SECRET_PATH="${REPO_ROOT}/state/test/pty-jwt-secret"
    export AB_TEST_AGENT1_STATE_DIR="./state/test/agent1/data"
    export AB_TEST_AGENT1_JWT_SECRET_PATH="${REPO_ROOT}/state/test/agent1/.jwt-secret"
    export AB_TEST_AGENT1_PORT="${TEST_AGENT1_PORT}"
    export AB_TEST_AGENT2_STATE_DIR="./state/test/agent2/data"
    export AB_TEST_AGENT2_JWT_SECRET_PATH="${REPO_ROOT}/state/test/agent2/.jwt-secret"
    export AB_TEST_AGENT2_PORT="${TEST_AGENT2_PORT}"
    docker compose -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.test.yml down --remove-orphans
  )
}

main() {
  require_docker
  load_env
  require_nonempty_envs \
    AB_TEST_COMPOSE_PROJECT_NAME \
    AB_TEST_BACKEND_PORT \
    AB_TEST_FRONT_PORT \
    AB_TEST_AGENT1_PORT \
    AB_TEST_AGENT2_PORT
  TEST_PROJECT_NAME="${AB_TEST_COMPOSE_PROJECT_NAME}"
  TEST_BACKEND_PORT="${AB_TEST_BACKEND_PORT}"
  TEST_FRONT_PORT="${AB_TEST_FRONT_PORT}"
  TEST_AGENT1_PORT="${AB_TEST_AGENT1_PORT}"
  TEST_AGENT2_PORT="${AB_TEST_AGENT2_PORT}"
  run_test_compose_down
}

main "$@"
