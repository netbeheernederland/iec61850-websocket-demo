#!/usr/bin/env bash
# Shared helpers sourced by the setup/ scripts. Not meant to be run directly.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SETUP_DIR
IMAGES_DIR="${SETUP_DIR}/images"
BUILD_DIR="${SETUP_DIR}/build"
CERTS_SRC="${SETUP_DIR}/certs"

if [[ -t 1 ]]; then c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
else c_g=; c_y=; c_r=; c_0=; fi
log()  { printf '%s==>%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

load_config() {
  # shellcheck disable=SC1091
  source "${SETUP_DIR}/roles.env"
  # shellcheck disable=SC1091
  source "${SETUP_DIR}/nodes.env"
  if [[ -z "${SSH_PUBKEY:-}" ]]; then
    local k
    for k in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
      [[ -f "$k" ]] && { SSH_PUBKEY="$(<"$k")"; break; }
    done
  fi
  export SSH_PUBKEY
}

# Deterministic locally-administered MAC from a node name: 52:54:00:xx:xx:xx
node_mac() {
  local h; h="$(printf '%s' "$1" | md5sum | cut -c1-6)"
  printf '52:54:00:%s:%s:%s' "${h:0:2}" "${h:2:2}" "${h:4:2}"
}

# Run $1 once per node with NODE_NAME/NODE_ROLE/NODE_IP/NODE_MAC/NODE_EXTRA set.
for_each_node() {
  local fn="$1" line
  for line in "${NODES[@]}"; do
    read -r NODE_NAME NODE_ROLE NODE_IP NODE_EXTRA <<<"$line"
    NODE_MAC="$(node_mac "$NODE_NAME")"
    "$fn"
  done
}

# Pull KEY out of NODE_EXTRA ("cp=cp1 port=5001 model=") -> value or "".
extra() {
  local k="$1" tok
  for tok in ${NODE_EXTRA:-}; do
    if [[ "$tok" == "$k="* ]]; then printf '%s' "${tok#*=}"; return 0; fi
  done
  return 0
}

# role_field <role> <0=vcpus|1=ram_mb|2=disk>
role_field() {
  local spec="${ROLE_SPEC[$1]:-}"
  [[ -n "$spec" ]] || die "no ROLE_SPEC entry for role '$1'"
  awk -v i="$(( $2 + 1 ))" '{print $i}' <<<"$spec"
}
