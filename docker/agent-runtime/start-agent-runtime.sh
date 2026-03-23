#!/usr/bin/env bash
set -euo pipefail

: "${AB_PTY_RELEASE_TAG:?AB_PTY_RELEASE_TAG is required}"
: "${AB_PTY_RELEASE_REPO:?AB_PTY_RELEASE_REPO is required}"
: "${AB_PTY_PORT:?AB_PTY_PORT is required}"
: "${AB_PTY_DATABASE:?AB_PTY_DATABASE is required}"

case "$(uname -m)" in
  x86_64|amd64)
    asset_name="ab-pty-linux-amd64-glibc"
    ;;
  aarch64|arm64)
    asset_name="ab-pty-linux-arm64-glibc"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

install_dir="/opt/agent-bridge/bin"
binary_path="${install_dir}/ab-pty"
tmp_file="$(mktemp)"
release_url="https://github.com/${AB_PTY_RELEASE_REPO}/releases/download/${AB_PTY_RELEASE_TAG}/${asset_name}"

cleanup() {
  rm -f "${tmp_file}"
}
trap cleanup EXIT

mkdir -p "${install_dir}"

if [[ -n "${AB_PTY_DOWNLOAD_TOKEN:-}" ]]; then
  release_api="https://api.github.com/repos/${AB_PTY_RELEASE_REPO}/releases/tags/${AB_PTY_RELEASE_TAG}"
  asset_id="$(curl -fsSL \
    -H "Authorization: Bearer ${AB_PTY_DOWNLOAD_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${release_api}" | jq -r --arg name "${asset_name}" '.assets[] | select(.name == $name) | .id')"

  if [[ -z "${asset_id}" || "${asset_id}" == "null" ]]; then
    echo "Release asset not found: ${asset_name} (${AB_PTY_RELEASE_REPO}@${AB_PTY_RELEASE_TAG})" >&2
    exit 1
  fi

  curl -fsSL \
    -H "Authorization: Bearer ${AB_PTY_DOWNLOAD_TOKEN}" \
    -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/${AB_PTY_RELEASE_REPO}/releases/assets/${asset_id}" \
    -o "${tmp_file}"
else
  curl -fsSL "${release_url}" -o "${tmp_file}"
fi

install -m 0755 "${tmp_file}" "${binary_path}"

exec "${binary_path}"
