#!/usr/bin/env bash
# Download + checksum-verify the Ubuntu cloud image used as the base for every
# demo VM. Idempotent: skips the download when the local copy already matches
# the published SHA256.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need curl; need sha256sum

mkdir -p "$IMAGES_DIR"
img="${IMAGES_DIR}/${UBUNTU_IMAGE}"
sums="${IMAGES_DIR}/SHA256SUMS.${UBUNTU_RELEASE}"

log "fetching checksum manifest"
curl -fsSL -o "$sums" "${UBUNTU_BASE_URL}/SHA256SUMS"
want="$(awk -v f="*${UBUNTU_IMAGE}" '$2==f {print $1}' "$sums")"
[[ -n "$want" ]] || die "no checksum for ${UBUNTU_IMAGE} in manifest"

if [[ -f "$img" ]] && [[ "$(sha256sum "$img" | cut -d' ' -f1)" == "$want" ]]; then
  log "${UBUNTU_IMAGE} already present and verified"
  exit 0
fi

log "downloading ${UBUNTU_IMAGE} (~600 MB)"
curl -fL --progress-bar -o "${img}.part" "${UBUNTU_BASE_URL}/${UBUNTU_IMAGE}"
got="$(sha256sum "${img}.part" | cut -d' ' -f1)"
[[ "$got" == "$want" ]] || die "checksum mismatch: got ${got} want ${want}"
mv "${img}.part" "$img"
log "saved ${img}"
