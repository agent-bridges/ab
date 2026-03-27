#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/gen-certs.sh <browser|daemon|all> [options]

Modes:
  browser   Generate browser HTTPS + optional browser mTLS materials
  daemon    Generate remote daemon HTTPS + backend client mTLS materials
  all       Generate both browser and daemon materials

Options:
  --browser-host <host>   Add browser TLS SAN entry (repeatable)
  --daemon-host <host>    Add daemon TLS SAN entry (repeatable)
  --browser-out <dir>     Output directory for browser materials
  --daemon-out <dir>      Output directory for daemon materials
  --help                  Show this help

Defaults:
  browser hosts: localhost, 127.0.0.1
  daemon hosts: localhost, 127.0.0.1
  browser out:  ./state/tls/browser
  daemon out:   ./state/tls/daemon
EOF
}

require_openssl() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required" >&2
    exit 1
  fi
}

is_ip_literal() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "${value}" == *:* ]]
}

write_extfile() {
  local path="$1"
  local usage="$2"
  shift 2
  local dns_index=1
  local ip_index=1
  local host

  {
    echo "[v3_req]"
    echo "subjectAltName=@alt_names"
    echo "extendedKeyUsage=${usage}"
    echo
    echo "[alt_names]"
    for host in "$@"; do
      if is_ip_literal "${host}"; then
        echo "IP.${ip_index}=${host}"
        ip_index=$((ip_index + 1))
      else
        echo "DNS.${dns_index}=${host}"
        dns_index=$((dns_index + 1))
      fi
    done
  } > "${path}"
}

generate_ca() {
  local out_dir="$1"
  local prefix="$2"
  local common_name="$3"

  openssl genrsa -out "${out_dir}/${prefix}.key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "${out_dir}/${prefix}.key" \
    -sha256 -days 3650 \
    -out "${out_dir}/${prefix}.crt" \
    -subj "/CN=${common_name}" >/dev/null 2>&1
}

generate_signed_cert() {
  local out_dir="$1"
  local prefix="$2"
  local common_name="$3"
  local ca_prefix="$4"
  local usage="$5"
  shift 5
  local extfile="${out_dir}/${prefix}.ext"

  openssl genrsa -out "${out_dir}/${prefix}.key" 2048 >/dev/null 2>&1
  openssl req -new \
    -key "${out_dir}/${prefix}.key" \
    -out "${out_dir}/${prefix}.csr" \
    -subj "/CN=${common_name}" >/dev/null 2>&1

  write_extfile "${extfile}" "${usage}" "$@"

  openssl x509 -req \
    -in "${out_dir}/${prefix}.csr" \
    -CA "${out_dir}/${ca_prefix}.crt" \
    -CAkey "${out_dir}/${ca_prefix}.key" \
    -CAcreateserial \
    -out "${out_dir}/${prefix}.crt" \
    -days 825 \
    -sha256 \
    -extfile "${extfile}" \
    -extensions v3_req >/dev/null 2>&1

  rm -f "${out_dir}/${prefix}.csr" "${extfile}"
}

print_browser_summary() {
  local out_dir="$1"
  cat <<EOF

Browser TLS materials
  Server cert:   ${out_dir}/server.crt
  Server key:    ${out_dir}/server.key
  Browser CA:    ${out_dir}/browser-ca.crt
  Browser client cert: ${out_dir}/browser-client.crt
  Browser client key:  ${out_dir}/browser-client.key
  Browser client bundle: ${out_dir}/browser-client.p12

Use with:
  AB_TLS_CERT_MOUNT_SRC=${out_dir}/server.crt
  AB_TLS_KEY_MOUNT_SRC=${out_dir}/server.key
  AB_TLS_BROWSER_CA_MOUNT_SRC=${out_dir}/browser-ca.crt

Stack commands:
  scripts/stack.sh up --mode prod --tls
  scripts/stack.sh up --mode prod --tls --browser-mtls
EOF
}

print_daemon_summary() {
  local out_dir="$1"
  cat <<EOF

Daemon TLS materials
  Daemon CA:      ${out_dir}/ca.crt
  Daemon CA key:  ${out_dir}/ca.key
  Daemon server cert: ${out_dir}/server.crt
  Daemon server key:  ${out_dir}/server.key
  Backend client cert: ${out_dir}/client.crt
  Backend client key:  ${out_dir}/client.key

Mount into back:
  AB_BACK_PTY_TLS_CA_MOUNT_SRC=${out_dir}/ca.crt
  AB_BACK_PTY_TLS_CLIENT_CERT_MOUNT_SRC=${out_dir}/client.crt
  AB_BACK_PTY_TLS_CLIENT_KEY_MOUNT_SRC=${out_dir}/client.key

Use with:
  scripts/stack.sh up --mode prod --daemon-https
  scripts/stack.sh up --mode prod --daemon-https --daemon-mtls

Deploy to the daemon host TLS proxy:
  server.crt
  server.key
  ca.crt
EOF
}

generate_browser_materials() {
  local out_dir="$1"
  shift
  local hosts=("$@")
  mkdir -p "${out_dir}"

  generate_ca "${out_dir}" "browser-ca" "Agent Bridge Browser CA"
  generate_signed_cert "${out_dir}" "server" "${hosts[0]}" "browser-ca" "serverAuth" "${hosts[@]}"
  generate_signed_cert "${out_dir}" "browser-client" "Agent Bridge Browser Client" "browser-ca" "clientAuth" "agent-bridge-browser"

  openssl pkcs12 -export \
    -out "${out_dir}/browser-client.p12" \
    -inkey "${out_dir}/browser-client.key" \
    -in "${out_dir}/browser-client.crt" \
    -certfile "${out_dir}/browser-ca.crt" \
    -passout pass: >/dev/null 2>&1

  print_browser_summary "${out_dir}"
}

generate_daemon_materials() {
  local out_dir="$1"
  shift
  local hosts=("$@")
  mkdir -p "${out_dir}"

  generate_ca "${out_dir}" "ca" "Agent Bridge Daemon CA"
  generate_signed_cert "${out_dir}" "server" "${hosts[0]}" "ca" "serverAuth" "${hosts[@]}"
  generate_signed_cert "${out_dir}" "client" "Agent Bridge Backend Client" "ca" "clientAuth" "agent-bridge-backend"

  print_daemon_summary "${out_dir}"
}

MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
  usage
  exit 1
fi
shift

case "${MODE}" in
  browser|daemon|all)
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    usage
    exit 1
    ;;
esac

require_openssl

BROWSER_OUT="${REPO_ROOT}/state/tls/browser"
DAEMON_OUT="${REPO_ROOT}/state/tls/daemon"
BROWSER_HOSTS=("localhost" "127.0.0.1")
DAEMON_HOSTS=("localhost" "127.0.0.1")
BROWSER_HOSTS_DEFAULTED=1
DAEMON_HOSTS_DEFAULTED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser-host)
      if [[ "${BROWSER_HOSTS_DEFAULTED}" == "1" ]]; then
        BROWSER_HOSTS=()
        BROWSER_HOSTS_DEFAULTED=0
      fi
      BROWSER_HOSTS+=("${2:?missing value for --browser-host}")
      shift 2
      ;;
    --daemon-host)
      if [[ "${DAEMON_HOSTS_DEFAULTED}" == "1" ]]; then
        DAEMON_HOSTS=()
        DAEMON_HOSTS_DEFAULTED=0
      fi
      DAEMON_HOSTS+=("${2:?missing value for --daemon-host}")
      shift 2
      ;;
    --browser-out)
      BROWSER_OUT="${2:?missing value for --browser-out}"
      shift 2
      ;;
    --daemon-out)
      DAEMON_OUT="${2:?missing value for --daemon-out}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "${MODE}" in
  browser)
    generate_browser_materials "${BROWSER_OUT}" "${BROWSER_HOSTS[@]}"
    ;;
  daemon)
    generate_daemon_materials "${DAEMON_OUT}" "${DAEMON_HOSTS[@]}"
    ;;
  all)
    generate_browser_materials "${BROWSER_OUT}" "${BROWSER_HOSTS[@]}"
    generate_daemon_materials "${DAEMON_OUT}" "${DAEMON_HOSTS[@]}"
    ;;
esac
