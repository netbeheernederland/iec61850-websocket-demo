#!/usr/bin/env bash
# Put a login on a Raspberry Pi: write cloud-init user-data to the boot
# partition that creates ${VM_USER} with SSH_PUBKEY, sudo, docker and i2c, and sets
# the hostname. The stock Ubuntu user-data only has `ubuntu` with password SSH
# login disabled, so without this a flashed Pi cannot be reached.
#
#   ./pi-user-data.sh --rpi 5 [--hostname rti-pi5]   # images/base-rti-rpi5.img, before flashing
#   ./pi-user-data.sh --image FILE [--hostname NAME]  # any raw Pi image
#   ./pi-user-data.sh --boot-dir DIR [--hostname NAME] # a flashed card's mounted system-boot
#
# Each run also gives meta-data a new instance id, so cloud-init applies the
# user-data again on a card that has already booted.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config

usage() {
  sed -n '7,9s/^#  //p' "$0"
  exit "${1:-0}"
}

image= boot_dir= hostname=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpi)
      [[ $# -ge 2 ]] || die "--rpi requires 3, 4 or 5"
      case "$2" in 3|4|5) ;; *) die "unsupported Raspberry Pi model: $2 (choose 3, 4 or 5)" ;; esac
      image="${IMAGES_DIR}/base-rti-rpi$2.img"; hostname="${hostname:-rti-pi$2}"
      shift 2 ;;
    --image)    [[ $# -ge 2 ]] || die "--image requires a file"; image="$2"; shift 2 ;;
    --boot-dir) [[ $# -ge 2 ]] || die "--boot-dir requires a directory"; boot_dir="$2"; shift 2 ;;
    --hostname) [[ $# -ge 2 ]] || die "--hostname requires a name"; hostname="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done
[[ -n "$image" || -n "$boot_dir" ]] || usage 1
[[ -z "$image" || -z "$boot_dir" ]] || die "use either --rpi/--image or --boot-dir, not both"
hostname="${hostname:-rti-pi}"
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid hostname: ${hostname}"
check_ssh_pubkey

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "${work}/user-data" <<EOF
#cloud-config
# Written by setup/pi-user-data.sh.
hostname: ${hostname}
manage_etc_hosts: localhost
preserve_hostname: false

# i2c-tools creates i2c and gives it /dev/i2c-*; listing it here first means
# the user is still created on an image built before i2c-tools was added.
groups: [i2c]

users:
  - name: ${VM_USER}
    groups: [sudo, docker, i2c]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

ssh_pwauth: false
EOF

# Keep the existing meta-data (dsmode etc.) and its key spelling; only the
# instance id changes.
new_meta() { # <in> <out>
  local id; id="${hostname}-$(date +%Y%m%d%H%M%S)"
  if grep -qE '^instance[_-]id:' "$1"; then
    sed -E "s/^(instance[_-]id:).*/\\1 ${id}/" "$1" > "$2"
  else
    { cat "$1"; printf 'instance-id: %s\n' "$id"; } > "$2"
  fi
}

if [[ -n "$boot_dir" ]]; then
  [[ -f "${boot_dir}/config.txt" ]] || die "${boot_dir} does not look like a Pi boot partition (no config.txt)"
  touch "${boot_dir}/meta-data"
  new_meta "${boot_dir}/meta-data" "${work}/meta-data"
  cp "${work}/user-data" "${boot_dir}/user-data"
  cp "${work}/meta-data" "${boot_dir}/meta-data"
  sync
  target="$boot_dir"
else
  need mcopy; need mtype; need partx
  [[ -f "$image" ]] || die "image not found: ${image} (run ./build-base.sh first)"
  start="$(partx -g -o START -n 1 "$image" | tr -d ' ')"
  [[ "$start" =~ ^[0-9]+$ ]] || die "cannot find the boot partition in ${image}"
  fat="${image}@@$((start * 512))"
  mtype -i "$fat" ::config.txt >/dev/null 2>&1 || die "partition 1 of ${image} is not a Pi boot partition"
  mtype -i "$fat" ::meta-data > "${work}/meta-data.old" 2>/dev/null || : > "${work}/meta-data.old"
  new_meta "${work}/meta-data.old" "${work}/meta-data"
  mcopy -o -i "$fat" "${work}/user-data" ::user-data
  mcopy -o -i "$fat" "${work}/meta-data" ::meta-data
  target="$image"
fi

log "wrote user-data to ${target}: user ${VM_USER}, hostname ${hostname}, key ${SSH_PUBKEY:0:24}…"
log "after boot: ssh ${VM_USER}@${hostname}.local  (or ssh ${VM_USER}@<dhcp address>)"
