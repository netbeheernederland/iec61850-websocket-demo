#!/usr/bin/env bash
# For each node build a boot disk:
#   * qcow2 overlay on images/base-rti.qcow2
#   * copy in  /etc/rti/compose.yaml, the role's image tarballs, and (fsp) the
#     model files, via virt-customize
#   * a NoCloud seed ISO from build/<node>/{user-data,meta-data}
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need qemu-img; need virt-customize
if command -v cloud-localds >/dev/null 2>&1; then SEED_TOOL=cloud-localds
elif command -v genisoimage  >/dev/null 2>&1; then SEED_TOOL=genisoimage
else die "need cloud-localds (cloud-image-utils) or genisoimage"; fi

base="${IMAGES_DIR}/base-rti.qcow2"
[[ -f "$base" ]] || die "run ./build-base.sh first (${base} missing)"

make_seed() { # <out.iso> <user-data> <meta-data>
  if [[ "$SEED_TOOL" == cloud-localds ]]; then
    cloud-localds "$1" "$2" "$3"
  else
    local t; t="$(mktemp -d)"
    cp "$2" "$t/user-data"; cp "$3" "$t/meta-data"
    genisoimage -quiet -output "$1" -volid cidata -joliet -rock \
      "$t/user-data" "$t/meta-data"
    rm -rf "$t"
  fi
}

build_one() {
  local d="${BUILD_DIR}/${NODE_NAME}"
  [[ -f "$d/user-data" ]] || die "run ./render.sh first (${NODE_NAME})"
  # shellcheck disable=SC1091
  source "$d/spec"

  local disk="${d}/${NODE_NAME}.qcow2"
  log "[${NODE_NAME}] overlay disk (${DISK})"
  rm -f "$disk"
  qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" >/dev/null
  qemu-img resize "$disk" "$DISK" >/dev/null

  local -a cust=( --mkdir /etc/rti --mkdir /var/lib/rti/images
                  --copy-in "${d}/compose.yaml:/etc/rti" )
  local tb
  for tb in ${ROLE_TARBALLS[$NODE_ROLE]}; do
    [[ -f "${IMAGES_DIR}/${tb}.tar" ]] \
      || die "missing images/${tb}.tar - run ./build-tarballs.sh"
    cust+=( --copy-in "${IMAGES_DIR}/${tb}.tar:/var/lib/rti/images" )
  done
  if [[ "$NODE_ROLE" == fsp ]]; then
    cust+=( --mkdir /etc/rti/models )
    local f found=0
    for f in "${FSP_MODELS_SRC}"/*.py; do
      [[ -e "$f" ]] || continue
      cust+=( --copy-in "${f}:/etc/rti/models" ); found=1
    done
    [[ $found -eq 1 ]] || warn "[${NODE_NAME}] no *.py in ${FSP_MODELS_SRC}"
  fi

  log "[${NODE_NAME}] virt-customize copy-in"
  virt-customize -a "$disk" "${cust[@]}" >/dev/null

  log "[${NODE_NAME}] seed iso"
  rm -f "${d}/seed.iso"
  make_seed "${d}/seed.iso" "${d}/user-data" "${d}/meta-data"
}
for_each_node build_one
log "disks + seeds ready under ${BUILD_DIR}/<node>/"
