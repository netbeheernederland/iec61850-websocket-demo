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

# Shared target selection for downloading and baking base images.
parse_image_target() {
  IMAGE_TARGET=vm
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rpi)
        [[ $# -ge 2 ]] || die "--rpi requires 3, 4 or 5"
        case "$2" in 3|4|5) IMAGE_TARGET="rpi$2" ;; *) die "unsupported Raspberry Pi model: $2 (choose 3, 4 or 5)" ;; esac
        shift 2 ;;
      -h|--help)
        printf 'Usage: %s [--rpi 3|4|5]\nDefault: amd64 VM image. --rpi selects a flashable ARM64 Raspberry Pi image.\n' "$(basename "$0")"
        exit 0 ;;
      *) die "unknown argument: $1 (use --help)" ;;
    esac
  done
  IMAGE_BASE_OUTPUT="${IMAGES_DIR}/base-rti.qcow2"
  IMAGE_FORMAT=qcow2
  if [[ "$IMAGE_TARGET" != vm ]]; then
    UBUNTU_ARCH=arm64
    UBUNTU_BASE_URL="$RPI_BASE_URL"
    IMAGE_BASE_OUTPUT="${IMAGES_DIR}/base-rti-${IMAGE_TARGET}.img"
    IMAGE_FORMAT=raw
  fi
}

# Resolve the current point-release filename from Ubuntu's checksum manifest.
resolve_image_name() {
  local manifest="$1"
  if [[ "$IMAGE_TARGET" != vm ]]; then
    UBUNTU_IMAGE="$(awk -v release="$UBUNTU_RELEASE" '
      { name=$2; sub(/^\*/, "", name)
        prefix="ubuntu-" release
        if (index(name, prefix)==1 &&
            substr(name, length(prefix)+1) ~ /^[.-]/ &&
            name ~ /-preinstalled-server-arm64\+raspi\.img\.xz$/) print name
      }' "$manifest" | sort -V | tail -n 1)"
    [[ -n "$UBUNTU_IMAGE" ]] || die "no Raspberry Pi server image for Ubuntu ${UBUNTU_RELEASE} in manifest"
  fi
}

load_config() {
  # shellcheck disable=SC1091
  source "${SETUP_DIR}/roles.env"
  # shellcheck disable=SC1091
  source "${SETUP_DIR}/nodes.env"
  local k
  if [[ -z "${SSH_PUBKEY:-}" ]]; then
    for k in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
      [[ -f "$k" ]] && { SSH_PUBKEY="$(<"$k")"; break; }
    done
  else
    # Also accept a key file: a path, or a file name under ~/.ssh.
    for k in "$SSH_PUBKEY" "${HOME}/.ssh/${SSH_PUBKEY}"; do
      [[ -f "$k" ]] && { SSH_PUBKEY="$(<"$k")"; break; }
    done
  fi
  export SSH_PUBKEY
}

# Die unless SSH_PUBKEY holds an OpenSSH public key line.
check_ssh_pubkey() {
  [[ -n "${SSH_PUBKEY:-}" ]] \
    || die "no SSH_PUBKEY: put a key at ~/.ssh/id_ed25519.pub or export SSH_PUBKEY=<key or .pub file>"
  [[ "$SSH_PUBKEY" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/=]+ ]] \
    || die "SSH_PUBKEY is not a public key or a readable .pub file: ${SSH_PUBKEY}"
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
