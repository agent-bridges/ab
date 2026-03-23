#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TEST_PROJECT_NAME=""
TEST_BACKEND_PORT=""
TEST_FRONT_PORT=""
TEST_AGENT1_PORT=""
TEST_AGENT2_PORT=""

TEST_ROOT="${REPO_ROOT}/state/test"
TEST_BACK_STATE_DIR="${TEST_ROOT}/back"
TEST_PTY_STATE_DIR="${TEST_ROOT}/pty"
TEST_PTY_CLAUDE_DIR="${TEST_PTY_STATE_DIR}/dot-claude"
TEST_PTY_CLAUDE_JSON_PATH="${TEST_PTY_STATE_DIR}/claude.json"
TEST_AGENT1_ROOT="${TEST_ROOT}/agent1"
TEST_AGENT1_STATE_DIR="${TEST_AGENT1_ROOT}/data"
TEST_AGENT2_ROOT="${TEST_ROOT}/agent2"
TEST_AGENT2_STATE_DIR="${TEST_AGENT2_ROOT}/data"
TEST_PTY_SECRET_PATH="${TEST_ROOT}/pty-jwt-secret"
TEST_AGENT1_SECRET_PATH="${TEST_AGENT1_ROOT}/.jwt-secret"
TEST_AGENT2_SECRET_PATH="${TEST_AGENT2_ROOT}/.jwt-secret"
TEST_DB_PATH="${TEST_BACK_STATE_DIR}/ab.db"
MAIN_DB_PATH="${REPO_ROOT}/state/back/ab.db"

TEST_ADMIN_USERNAME=""
TEST_ADMIN_PASSWORD=""
TEST_REMOTE_AGENT1_NAME=""
TEST_REMOTE_AGENT1_IP=""
TEST_REMOTE_AGENT2_NAME=""
TEST_REMOTE_AGENT2_IP=""

confirm() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local suffix="[y/N]"
  local input=""

  if [[ "${default_answer}" == "Y" ]]; then
    suffix="[Y/n]"
  fi

  read -r -p "${prompt} ${suffix} " input
  input="${input:-$default_answer}"
  [[ "${input}" =~ ^[Yy]$ ]]
}

require_core_layout() {
  load_env

  local back_path front_path pty_path
  back_path="$(resolve_path "${AB_BACK_PATH}")"
  front_path="$(resolve_path "${AB_FRONT_PATH}")"
  pty_path="$(resolve_path "${AB_PTY_PATH}")"

  local missing=0
  for path in "${back_path}" "${front_path}" "${pty_path}"; do
    if [[ ! -d "${path}" ]]; then
      echo "Missing path: ${path}" >&2
      missing=1
    fi
    if [[ ! -d "${path}/.git" ]]; then
      echo "Missing child repo metadata: ${path}/.git" >&2
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

require_host_tools() {
  local missing=0
  local tools=(bash curl python3 realpath)

  for tool in "${tools[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Required host tool is missing: ${tool}" >&2
      missing=1
    fi
  done

  if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose plugin is required" >&2
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

assert_port_available() {
  local port="$1"
  local label="$2"

  PORT="${port}" LABEL="${label}" python3 - <<'PY'
import os
import socket
import sys

port = int(os.environ["PORT"])
label = os.environ["LABEL"]

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    print(f"{label} port is already in use on 127.0.0.1:{port}", file=sys.stderr)
    sys.exit(1)
finally:
    sock.close()
PY
}

check_test_ports() {
  assert_port_available "${TEST_BACKEND_PORT}" "Test backend"
  assert_port_available "${TEST_FRONT_PORT}" "Test front"
  assert_port_available "${TEST_AGENT1_PORT}" "Test agent 1"
  assert_port_available "${TEST_AGENT2_PORT}" "Test agent 2"
}

prepare_test_state() {
  mkdir -p \
    "${TEST_BACK_STATE_DIR}" \
    "${TEST_PTY_CLAUDE_DIR}" \
    "${TEST_AGENT1_STATE_DIR}" \
    "${TEST_AGENT2_STATE_DIR}"

  : > "${TEST_PTY_CLAUDE_JSON_PATH}"

  rm -f \
    "${TEST_DB_PATH}" \
    "${TEST_PTY_STATE_DIR}/sessions.db" \
    "${TEST_AGENT1_STATE_DIR}/sessions.db" \
    "${TEST_AGENT2_STATE_DIR}/sessions.db"
}

generate_secrets_and_tokens() {
  mapfile -t _test_values < <(
    TEST_PTY_SECRET_PATH="${TEST_PTY_SECRET_PATH}" \
    TEST_AGENT1_SECRET_PATH="${TEST_AGENT1_SECRET_PATH}" \
    TEST_AGENT2_SECRET_PATH="${TEST_AGENT2_SECRET_PATH}" \
    python3 - <<'PY'
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path

pty_secret_path = Path(os.environ["TEST_PTY_SECRET_PATH"])
agent1_secret_path = Path(os.environ["TEST_AGENT1_SECRET_PATH"])
agent2_secret_path = Path(os.environ["TEST_AGENT2_SECRET_PATH"])

for path in (pty_secret_path, agent1_secret_path, agent2_secret_path):
    path.parent.mkdir(parents=True, exist_ok=True)

pty_secret = secrets.token_hex(32)
agent1_secret = secrets.token_hex(32)
agent2_secret = secrets.token_hex(32)

pty_secret_path.write_text(pty_secret)
agent1_secret_path.write_text(agent1_secret)
agent2_secret_path.write_text(agent2_secret)
os.chmod(pty_secret_path, 0o600)
os.chmod(agent1_secret_path, 0o600)
os.chmod(agent2_secret_path, 0o600)

def jwt_hs256(secret: str, sub: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "sub": sub,
        "iat": int(time.time()),
        "exp": int(time.time() + 365 * 24 * 60 * 60),
    }

    def b64(data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    signing_input = f"{b64(json.dumps(header, separators=(',', ':')).encode())}.{b64(json.dumps(payload, separators=(',', ':')).encode())}"
    signature = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64(signature)}"

print(jwt_hs256(agent1_secret, "ab-pty"))
print(jwt_hs256(agent2_secret, "ab-pty"))
PY
  )

  TEST_REMOTE_AGENT1_JWT="${_test_values[0]}"
  TEST_REMOTE_AGENT2_JWT="${_test_values[1]}"
}

hash_password() {
  TEST_ADMIN_PASSWORD="${TEST_ADMIN_PASSWORD}" python3 - <<'PY'
import hashlib
import os
import secrets

password = os.environ["TEST_ADMIN_PASSWORD"]
scheme = "pbkdf2_sha256"
iterations = 310000
salt = secrets.token_bytes(16)
digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
print(f"{scheme}${iterations}${salt.hex()}${digest.hex()}")
PY
}

wait_for_url() {
  local url="$1"
  local label="$2"
  local attempts="${3:-60}"
  local i

  for ((i=1; i<=attempts; i++)); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "${label} did not become ready: ${url}" >&2
  exit 1
}

seed_test_database() {
  local password_hash="$1"

  TEST_DB_PATH="${TEST_DB_PATH}" \
  TEST_ADMIN_USERNAME="${TEST_ADMIN_USERNAME}" \
  TEST_PASSWORD_HASH="${password_hash}" \
  TEST_REMOTE_AGENT1_NAME="${TEST_REMOTE_AGENT1_NAME}" \
  TEST_REMOTE_AGENT1_IP="${TEST_REMOTE_AGENT1_IP}" \
  TEST_REMOTE_AGENT1_JWT="${TEST_REMOTE_AGENT1_JWT}" \
  TEST_REMOTE_AGENT2_NAME="${TEST_REMOTE_AGENT2_NAME}" \
  TEST_REMOTE_AGENT2_IP="${TEST_REMOTE_AGENT2_IP}" \
  TEST_REMOTE_AGENT2_JWT="${TEST_REMOTE_AGENT2_JWT}" \
  python3 - <<'PY'
import os
import sqlite3
from datetime import datetime, UTC

db_path = os.environ["TEST_DB_PATH"]
username = os.environ["TEST_ADMIN_USERNAME"]
password_hash = os.environ["TEST_PASSWORD_HASH"]
remote1_name = os.environ["TEST_REMOTE_AGENT1_NAME"]
remote1_ip = os.environ["TEST_REMOTE_AGENT1_IP"]
remote1_jwt = os.environ["TEST_REMOTE_AGENT1_JWT"]
remote2_name = os.environ["TEST_REMOTE_AGENT2_NAME"]
remote2_ip = os.environ["TEST_REMOTE_AGENT2_IP"]
remote2_jwt = os.environ["TEST_REMOTE_AGENT2_JWT"]
now = datetime.now(UTC).replace(tzinfo=None).isoformat(sep=" ")

conn = sqlite3.connect(db_path)
cur = conn.cursor()

cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('username', ?)", (username,))
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('password_hash', ?)", (password_hash,))
cur.execute("DELETE FROM auth_sessions")
cur.execute("DELETE FROM agents WHERE is_local = 1")

remote1_row = cur.execute("SELECT id FROM agents WHERE name = ?", (remote1_name,)).fetchone()
if remote1_row:
    cur.execute(
        "UPDATE agents SET ip = ?, jwt_key = ?, is_local = 0, updated_at = ? WHERE id = ?",
        (remote1_ip, remote1_jwt, now, remote1_row[0]),
    )
else:
    cur.execute(
        "INSERT INTO agents (name, ip, jwt_key, is_local, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)",
        (remote1_name, remote1_ip, remote1_jwt, now, now),
    )

remote2_row = cur.execute("SELECT id FROM agents WHERE name = ?", (remote2_name,)).fetchone()
if remote2_row:
    cur.execute(
        "UPDATE agents SET ip = ?, jwt_key = ?, is_local = 0, updated_at = ? WHERE id = ?",
        (remote2_ip, remote2_jwt, now, remote2_row[0]),
    )
else:
    cur.execute(
        "INSERT INTO agents (name, ip, jwt_key, is_local, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)",
        (remote2_name, remote2_ip, remote2_jwt, now, now),
    )

conn.commit()
conn.close()
PY
}

sync_main_demo_agents() {
  if [[ ! -f "${MAIN_DB_PATH}" ]]; then
    return
  fi

  MAIN_DB_PATH="${MAIN_DB_PATH}" \
  TEST_REMOTE_AGENT1_NAME="${TEST_REMOTE_AGENT1_NAME}" \
  TEST_REMOTE_AGENT1_JWT="${TEST_REMOTE_AGENT1_JWT}" \
  TEST_REMOTE_AGENT2_NAME="${TEST_REMOTE_AGENT2_NAME}" \
  TEST_REMOTE_AGENT2_JWT="${TEST_REMOTE_AGENT2_JWT}" \
  python3 - <<'PY'
import os
import sqlite3
from datetime import datetime, UTC

db_path = os.environ["MAIN_DB_PATH"]
remote1_name = os.environ["TEST_REMOTE_AGENT1_NAME"]
remote1_jwt = os.environ["TEST_REMOTE_AGENT1_JWT"]
remote2_name = os.environ["TEST_REMOTE_AGENT2_NAME"]
remote2_jwt = os.environ["TEST_REMOTE_AGENT2_JWT"]
now = datetime.now(UTC).replace(tzinfo=None).isoformat(sep=" ")

conn = sqlite3.connect(db_path)
cur = conn.cursor()

for name, jwt in ((remote1_name, remote1_jwt), (remote2_name, remote2_jwt)):
    row = cur.execute("SELECT id FROM agents WHERE name = ?", (name,)).fetchone()
    if row:
        cur.execute(
            "UPDATE agents SET jwt_key = ?, updated_at = ? WHERE id = ?",
            (jwt, now, row[0]),
        )

conn.commit()
conn.close()
PY
}

run_test_compose() {
  local command="$1"
  shift

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
    export AB_JWT_SECRET_PATH="${TEST_PTY_SECRET_PATH}"
    export AB_TEST_AGENT1_STATE_DIR="./state/test/agent1/data"
    export AB_TEST_AGENT1_JWT_SECRET_PATH="${TEST_AGENT1_SECRET_PATH}"
    export AB_TEST_AGENT1_PORT="${TEST_AGENT1_PORT}"
    export AB_TEST_AGENT2_STATE_DIR="./state/test/agent2/data"
    export AB_TEST_AGENT2_JWT_SECRET_PATH="${TEST_AGENT2_SECRET_PATH}"
    export AB_TEST_AGENT2_PORT="${TEST_AGENT2_PORT}"
    docker compose -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.test.yml "${command}" "$@"
  )
}

handle_existing_test_stack() {
  local existing
  existing="$(run_test_compose ps -q 2>/dev/null || true)"

  if [[ -z "${existing}" ]]; then
    return
  fi

  echo "Existing test stack detected for project ${TEST_PROJECT_NAME}."
  if ! confirm "Remove current test stack and recreate it?" "N"; then
    echo "Keeping current test stack. Exiting."
    exit 0
  fi

  run_test_compose down --remove-orphans
}

print_test_summary() {
  cat <<EOF
Test stack is ready.

Front:    http://127.0.0.1:${TEST_FRONT_PORT}
Backend:  http://127.0.0.1:${TEST_BACKEND_PORT}
Agent 1:  http://127.0.0.1:${TEST_AGENT1_PORT}/health
Agent 2:  http://127.0.0.1:${TEST_AGENT2_PORT}/health

Login:
  username: ${TEST_ADMIN_USERNAME}
  password: ${TEST_ADMIN_PASSWORD}

Seeded agents:
  - ${TEST_REMOTE_AGENT1_NAME} (${TEST_REMOTE_AGENT1_IP})
  - ${TEST_REMOTE_AGENT2_NAME} (${TEST_REMOTE_AGENT2_IP})
EOF
}

main() {
  require_docker
  load_env
  require_nonempty_envs \
    AB_TEST_COMPOSE_PROJECT_NAME \
    AB_TEST_BACKEND_PORT \
    AB_TEST_FRONT_PORT \
    AB_TEST_AGENT1_PORT \
    AB_TEST_AGENT2_PORT \
    AB_TEST_ADMIN_USERNAME \
    AB_TEST_ADMIN_PASSWORD \
    AB_TEST_AGENT1_NAME \
    AB_TEST_AGENT1_IP \
    AB_TEST_AGENT2_NAME \
    AB_TEST_AGENT2_IP
  TEST_PROJECT_NAME="${AB_TEST_COMPOSE_PROJECT_NAME}"
  TEST_BACKEND_PORT="${AB_TEST_BACKEND_PORT}"
  TEST_FRONT_PORT="${AB_TEST_FRONT_PORT}"
  TEST_AGENT1_PORT="${AB_TEST_AGENT1_PORT}"
  TEST_AGENT2_PORT="${AB_TEST_AGENT2_PORT}"
  TEST_ADMIN_USERNAME="${AB_TEST_ADMIN_USERNAME}"
  TEST_ADMIN_PASSWORD="${AB_TEST_ADMIN_PASSWORD}"
  TEST_REMOTE_AGENT1_NAME="${AB_TEST_AGENT1_NAME}"
  TEST_REMOTE_AGENT1_IP="${AB_TEST_AGENT1_IP}"
  TEST_REMOTE_AGENT2_NAME="${AB_TEST_AGENT2_NAME}"
  TEST_REMOTE_AGENT2_IP="${AB_TEST_AGENT2_IP}"
  require_host_tools
  require_core_layout
  handle_existing_test_stack
  check_test_ports
  prepare_test_state
  generate_secrets_and_tokens
  local password_hash
  password_hash="$(TEST_ADMIN_PASSWORD="${TEST_ADMIN_PASSWORD}" hash_password)"

  run_test_compose up -d --build

  wait_for_url "http://127.0.0.1:${TEST_BACKEND_PORT}/api/auth/status" "test backend"
  wait_for_url "http://127.0.0.1:${TEST_AGENT1_PORT}/health" "test agent 1"
  wait_for_url "http://127.0.0.1:${TEST_AGENT2_PORT}/health" "test agent 2"

  seed_test_database "${password_hash}"
  sync_main_demo_agents
  print_test_summary
}

main "$@"
