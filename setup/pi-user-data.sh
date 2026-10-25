#!/usr/bin/env bash
# Put a login on a Raspberry Pi: write cloud-init user-data to the boot
# partition that creates ${VM_USER} with SSH_PUBKEY, sudo, docker and i2c, and sets
# the hostname. The stock Ubuntu user-data only has `ubuntu` with password SSH
# login disabled, so without this a flashed Pi cannot be reached.
#
#   ./pi-user-data.sh --rpi 5 [--hostname rti-pi5]   # images/base-rti-rpi5.img -> images/rti-pi5.img
#   ./pi-user-data.sh --image FILE [--hostname NAME]  # any raw Pi image -> images/NAME.img
#   ./pi-user-data.sh --boot-dir DIR [--hostname NAME] # a flashed card's mounted system-boot, in place
#   ... --out FILE                                     # with --rpi/--image: write the new image here
#   ... --role so|fsp [--cp CP] [--port PORT] [--model FILE]   # also start a role on first boot
#
# With --rpi or --image the base image is left alone: the script writes a copy
# for this one Pi (default images/<hostname>.img, replaced if it exists) and
# flashes that. Rerun it for each Pi; the base stays reusable.
#
# With --role, the role's files (image archives, compose file, .env, model;
# see ../scripts/stage-rti-role.sh) go to rti/ on the boot partition. On first
# boot cloud-init moves them to ~${VM_USER}/rti, the directory
# deploy-rti-demo.sh uses, and runs load-and-start.sh there. The archives
# come from RTI_IMAGE_DIR (default ../dist/rti-images-arm64).
#
# Each run also gives meta-data a new instance id, so cloud-init applies the
# user-data again on a card that has already booted.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config

usage() {
  sed -n '7,11s/^#  //p' "$0"
  exit "${1:-0}"
}

STAGE_SCRIPT="${SETUP_DIR}/../scripts/stage-rti-role.sh"

image= boot_dir= hostname= out=
stage_args=()
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
    --out)      [[ $# -ge 2 ]] || die "--out requires a file"; out="$2"; shift 2 ;;
    --role|--cp|--port|--model)
      [[ $# -ge 2 ]] || die "$1 requires a value"; stage_args+=("$1" "$2"); shift 2 ;;
    -h|--help)  usage ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done
[[ -n "$image" || -n "$boot_dir" ]] || usage 1
[[ -z "$image" || -z "$boot_dir" ]] || die "use either --rpi/--image or --boot-dir, not both"
[[ -z "$out" || -z "$boot_dir" ]] || die "--out is for --rpi/--image; --boot-dir writes in place"
hostname="${hostname:-rti-pi}"
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid hostname: ${hostname}"
if [[ -n "$image" ]]; then
  [[ -f "$image" ]] || die "image not found: ${image} (run ./build-base.sh first)"
  out="${out:-${IMAGES_DIR}/${hostname}.img}"
  [[ ! "$out" -ef "$image" ]] || die "--out is the base image itself: ${out}"
fi
check_ssh_pubkey
role=
if [[ ${#stage_args[@]} -gt 0 ]]; then
  for ((i = 0; i < ${#stage_args[@]}; i += 2)); do
    [[ "${stage_args[i]}" == --role ]] && role="${stage_args[i+1]}"
  done
  [[ -n "$role" ]] || die "--cp, --port and --model need --role"
fi

work="$(mktemp -d)"
partial=
trap 'rm -rf "$work"; [[ -z "$partial" ]] || rm -f "$partial"' EXIT

# The role's files, checked and staged before anything is written.
if [[ -n "$role" ]]; then
  "$STAGE_SCRIPT" "${stage_args[@]}" "${work}/rti" || die "could not stage role ${role}"
fi

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

# First boot of a Pi with a role: move rti/ off the boot partition into the
# user's home, load the images and start compose. Without rti/ it does nothing.
if [[ -n "$role" ]]; then
  cat >> "${work}/user-data" <<EOF

write_files:
  - path: /usr/local/sbin/rti-first-deploy
    permissions: "0755"
    content: |
      #!/bin/bash
      # Written by setup/pi-user-data.sh: start this Pi's role (${role}).
      set -euo pipefail
      src=/boot/firmware/rti
      dst=/home/${VM_USER}/rti
      [ -d "\$src" ] || exit 0
      mkdir -p "\$dst"
      cp -r "\$src"/. "\$dst"/
      chown -R ${VM_USER}:${VM_USER} "\$dst"
      # Docker may still be starting when cloud-init gets here.
      for _ in \$(seq 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
      cd "\$dst"
      bash ./load-and-start.sh
      # Done: free the boot partition and do not run again.
      rm -rf "\$src"

runcmd:
  - [sh, -c, "/usr/local/sbin/rti-first-deploy > /var/log/rti-first-deploy.log 2>&1"]
EOF
fi

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
  rm -rf "${boot_dir}/rti"
  if [[ -n "$role" ]]; then
    cp -r "${work}/rti" "${boot_dir}/rti" \
      || die "could not copy the role files ($(du -sh "${work}/rti" | cut -f1)) to ${boot_dir}: full?"
  fi
  sync
  target="$boot_dir"
else
  need mcopy; need mtype; need partx
  start="$(partx -g -o START -n 1 "$image" | tr -d ' ')"
  [[ "$start" =~ ^[0-9]+$ ]] || die "cannot find the boot partition in ${image}"
  mtype -i "${image}@@$((start * 512))" ::config.txt >/dev/null 2>&1 \
    || die "partition 1 of ${image} is not a Pi boot partition"
  # Work on a copy next to the output; it replaces the output only when complete.
  mkdir -p "$(dirname "$out")"
  partial="${out}.partial"
  log "copying ${image} -> ${out}"
  cp --sparse=always --reflink=auto "$image" "$partial"
  fat="${partial}@@$((start * 512))"
  mtype -i "$fat" ::meta-data > "${work}/meta-data.old" 2>/dev/null || : > "${work}/meta-data.old"
  new_meta "${work}/meta-data.old" "${work}/meta-data"
  mcopy -o -i "$fat" "${work}/user-data" ::user-data
  mcopy -o -i "$fat" "${work}/meta-data" ::meta-data
  if mdir -i "$fat" ::rti >/dev/null 2>&1; then mdeltree -i "$fat" ::rti; fi
  if [[ -n "$role" ]]; then
    mcopy -s -i "$fat" "${work}/rti" :: \
      || die "could not copy the role files ($(du -sh "${work}/rti" | cut -f1)) to the boot partition: full?"
  fi
  mv "$partial" "$out"; partial=
  target="$out"
fi

log "wrote user-data to ${target}: user ${VM_USER}, hostname ${hostname}, key ${SSH_PUBKEY:0:24}…"
[[ -z "$role" ]] || log "role ${role}: starts on first boot; log in /var/log/rti-first-deploy.log"
[[ -z "$image" ]] || log "flash ${out} (balenaEtcher or dd); ${image} is unchanged"
log "after boot: ssh ${VM_USER}@${hostname}.local  (or ssh ${VM_USER}@<dhcp address>)"
