#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DEMO_AGENT_NAME=""
DEMO_AGENT_IP=""
DEMO_ROOT="${REPO_ROOT}/state/demo"
DEMO_AGENT_ROOT="${DEMO_ROOT}/agent"
DEMO_AGENT_STATE_DIR="${DEMO_AGENT_ROOT}/data"
DEMO_AGENT_SECRET_PATH="${DEMO_AGENT_ROOT}/.jwt-secret"

wait_for_back_db() {
  local db_dir db_path attempts

  db_dir="$(resolve_path "${AB_BACK_STATE_DIR}")"
  db_path="${db_dir}/ab.db"
  attempts=60

  BACK_DB_PATH="${db_path}" python3 - <<'PY'
import os
import sqlite3
import sys
import time
from pathlib import Path

db_path = Path(os.environ["BACK_DB_PATH"])

for _ in range(60):
    if db_path.exists():
        try:
            conn = sqlite3.connect(db_path)
            try:
                row = conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='agents'"
                ).fetchone()
                if row:
                    sys.exit(0)
            finally:
                conn.close()
        except sqlite3.Error:
            pass
    time.sleep(1)

print(f"Backend DB is not ready: {db_path}", file=sys.stderr)
sys.exit(1)
PY
}

exec_back_python() {
  local script="$1"
  shift || true

  run_compose exec -T "$@" back python3 - <<PY
${script}
PY
}

generate_demo_agent_jwt() {
  mkdir -p "${DEMO_AGENT_STATE_DIR}"

  if [[ -d "${DEMO_AGENT_SECRET_PATH}" ]]; then
    rm -rf "${DEMO_AGENT_SECRET_PATH}"
  fi

  if [[ ! -f "${DEMO_AGENT_SECRET_PATH}" ]]; then
    umask 077
    openssl rand -hex 32 > "${DEMO_AGENT_SECRET_PATH}"
  fi

  DEMO_AGENT_SECRET_PATH="${DEMO_AGENT_SECRET_PATH}" python3 - <<'PY'
import base64
import hashlib
import hmac
import json
import os
import time
from pathlib import Path

secret = Path(os.environ["DEMO_AGENT_SECRET_PATH"]).read_text().strip()
header = {"alg": "HS256", "typ": "JWT"}
payload = {
    "sub": "ab-pty",
    "iat": int(time.time()),
    "exp": int(time.time() + 365 * 24 * 60 * 60),
}

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

signing_input = (
    f"{b64(json.dumps(header, separators=(',', ':')).encode())}."
    f"{b64(json.dumps(payload, separators=(',', ':')).encode())}"
)
signature = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
print(f"{signing_input}.{b64(signature)}")
PY
}

upsert_demo_agent() {
  local demo_jwt
  demo_jwt="$(generate_demo_agent_jwt)"

  exec_back_python "$(cat <<'PY'
import os
import sqlite3
from datetime import UTC, datetime

db_path = "/state/back/ab.db"
name = os.environ["DEMO_AGENT_NAME"]
ip = os.environ["DEMO_AGENT_IP"]
jwt_key = os.environ["DEMO_AGENT_JWT"]
now = datetime.now(UTC).replace(tzinfo=None).isoformat(sep=" ")

conn = sqlite3.connect(db_path)
cur = conn.cursor()
row = cur.execute("SELECT id FROM agents WHERE name = ?", (name,)).fetchone()

if row:
    cur.execute(
        "UPDATE agents SET ip = ?, jwt_key = ?, is_local = 0, updated_at = ? WHERE id = ?",
        (ip, jwt_key, now, row[0]),
    )
else:
    cur.execute(
        "INSERT INTO agents (name, ip, jwt_key, is_local, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)",
        (name, ip, jwt_key, now, now),
    )

conn.commit()
conn.close()
PY
)" \
    -e DEMO_AGENT_NAME="${DEMO_AGENT_NAME}" \
    -e DEMO_AGENT_IP="${DEMO_AGENT_IP}" \
    -e DEMO_AGENT_JWT="${demo_jwt}"
}

remove_demo_agent() {
  local db_dir

  db_dir="$(resolve_path "${AB_BACK_STATE_DIR}")"
  if [[ ! -f "${db_dir}/ab.db" ]]; then
    return
  fi

  exec_back_python "$(cat <<'PY'
import os
import sqlite3

db_path = "/state/back/ab.db"
name = os.environ["DEMO_AGENT_NAME"]

conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("DELETE FROM agents WHERE name = ?", (name,))
conn.commit()
conn.close()
PY
)" -e DEMO_AGENT_NAME="${DEMO_AGENT_NAME}"
}

main() {
  local mode="${1:-upsert}"

  load_env
  ensure_state
  require_nonempty_envs AB_BACK_STATE_DIR AB_DEMO_AGENT_NAME AB_DEMO_AGENT_IP
  DEMO_AGENT_NAME="${AB_DEMO_AGENT_NAME}"
  DEMO_AGENT_IP="${AB_DEMO_AGENT_IP}"

  case "${mode}" in
    prepare|--prepare)
      generate_demo_agent_jwt >/dev/null
      ;;
    --remove|remove)
      remove_demo_agent
      ;;
    upsert|--upsert|"")
      wait_for_back_db
      upsert_demo_agent
      ;;
    *)
      echo "Unknown mode: ${mode}" >&2
      exit 1
      ;;
  esac
}

main "$@"
