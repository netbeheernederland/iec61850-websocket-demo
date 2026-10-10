#!/usr/bin/env bash
# Bake a golden image: Ubuntu cloud image + docker, avahi/nss-mdns and
# isc-dhcp-server preinstalled, so per-node cloud-init never has to touch apt
# (fast, deterministic, works even if the VM has no outbound DNS at boot).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
parse_image_target "$@"
need qemu-img

# Raspberry Pi images are ARM64. On an ARM64 host virt-customize runs them
# natively; elsewhere we chroot into the image through qemu-user emulation.
CUSTOMIZE=virt-customize
if [[ "$IMAGE_TARGET" != vm ]]; then
  need xz
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) CUSTOMIZE=chroot ;;
  esac
  sums="${IMAGES_DIR}/SHA256SUMS.${UBUNTU_RELEASE}.${IMAGE_TARGET}"
  [[ -f "$sums" ]] || die "run ./download-images.sh --rpi ${IMAGE_TARGET#rpi} first"
  resolve_image_name "$sums"
fi

if [[ "$CUSTOMIZE" == chroot ]]; then
  need sudo; need losetup; need parted; need e2fsck; need resize2fs; need chroot
  # The F (fix-binary) flag lets the kernel use the host's emulator from
  # inside the chroot without copying it into the image.
  binfmt=/proc/sys/fs/binfmt_misc/qemu-aarch64
  [[ -r "$binfmt" ]] && grep -qx enabled "$binfmt" && grep -q '^flags:.*F' "$binfmt" \
    || die "ARM64 emulation not registered. On Ubuntu run: sudo apt install qemu-user-static ; then rerun this script (see README.md)."
else
  need virt-customize
fi

# flash-kernel copies a new kernel/initrd to /boot/firmware, but skips itself
# in a chroot (which includes virt-customize) and can't detect a Pi model
# here, so it is rerun explicitly once the upgrade is done. All models share
# the same "pi" method; the name only has to match its database.
case "$IMAGE_TARGET" in
  rpi3) FK_MACHINE="Raspberry Pi 3 Model B Plus" ;;
  rpi4) FK_MACHINE="Raspberry Pi 4 Model B" ;;
  rpi5) FK_MACHINE="Raspberry Pi 5 Model B" ;;
  *)    FK_MACHINE= ;;
esac
FLASH_KERNEL_CMD="FK_FORCE=yes FK_IGNORE_EFI=yes FK_MACHINE='${FK_MACHINE}' flash-kernel"

# Same steps as the virt-customize call below, run as a script inside the
# chroot. Keep the two in sync.
RPI_GUEST_SCRIPT="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
apt-get -y install docker.io docker-compose-v2 avahi-daemon libnss-mdns isc-dhcp-server qemu-guest-agent
apt-get clean
systemctl enable docker qemu-guest-agent avahi-daemon rti-issue.timer
systemctl disable isc-dhcp-server
sed -ri 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
${FLASH_KERNEL_CMD}
rm -f /etc/machine-id && touch /etc/machine-id
echo rti-base > /etc/hostname
"
# Headroom for the upgrade and docker; the root partition only has ~1 GB
# free. cloud-init still grows it to fill the SD card on first boot.
RPI_IMAGE_GROW="${RPI_IMAGE_GROW:-2G}"

RPI_MNT=
RPI_LOOP=
rpi_chroot_cleanup() {
  if [[ -n "$RPI_MNT" ]]; then
    sudo rm -f "${RPI_MNT}/usr/sbin/policy-rc.d" || true
    sudo umount -R "$RPI_MNT" 2>/dev/null || sudo umount -lR "$RPI_MNT" 2>/dev/null || true
    rmdir "$RPI_MNT" 2>/dev/null || true
    RPI_MNT=
  fi
  if [[ -n "$RPI_LOOP" ]]; then
    sudo losetup -d "$RPI_LOOP" || true
    RPI_LOOP=
  fi
}

# Loop-mount the raw Pi image and run RPI_GUEST_SCRIPT in a chroot, with the
# kernel's binfmt_misc handing ARM64 binaries to qemu-user.
customize_rpi_chroot() {
  local img="$1"
  log "growing ${img} by ${RPI_IMAGE_GROW}"
  truncate -s "+${RPI_IMAGE_GROW}" "$img"
  parted -s "$img" resizepart 2 100%

  log "sudo is needed to loop-mount the image and chroot into it"
  sudo -v || die "sudo is required for Raspberry Pi builds on a non-ARM64 host"
  trap rpi_chroot_cleanup EXIT
  RPI_LOOP="$(sudo losetup -Pf --show "$img")"
  sudo e2fsck -pf "${RPI_LOOP}p2" || (( $? == 1 ))  # 1 = fixed, still fine
  sudo resize2fs "${RPI_LOOP}p2"

  RPI_MNT="$(mktemp -d)"
  sudo mount "${RPI_LOOP}p2" "$RPI_MNT"
  sudo mkdir -p "${RPI_MNT}/boot/firmware"
  sudo mount "${RPI_LOOP}p1" "${RPI_MNT}/boot/firmware"
  local d
  for d in dev dev/pts proc sys; do sudo mount --bind "/${d}" "${RPI_MNT}/${d}"; done
  # /etc/resolv.conf in the image links into /run; give it the host's resolver.
  sudo mount -t tmpfs tmpfs "${RPI_MNT}/run"
  sudo mkdir -p "${RPI_MNT}/run/systemd/resolve"
  sudo cp -L /etc/resolv.conf "${RPI_MNT}/run/systemd/resolve/stub-resolv.conf"
  sudo install -m 0755 "${SETUP_DIR}/base/rti-issue" "${RPI_MNT}/usr/local/sbin/"
  sudo install -m 0644 "${SETUP_DIR}/base/rti-issue.service" "${SETUP_DIR}/base/rti-issue.timer" \
    "${RPI_MNT}/etc/systemd/system/"
  # Keep package postinst scripts from starting services inside the chroot.
  printf '#!/bin/sh\nexit 101\n' | sudo tee "${RPI_MNT}/usr/sbin/policy-rc.d" >/dev/null
  sudo chmod 0755 "${RPI_MNT}/usr/sbin/policy-rc.d"

  log "installing packages under ARM64 emulation (needs network; expect 20+ minutes)"
  sudo chroot "$RPI_MNT" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root LANG=C.UTF-8 \
    /bin/bash -euo pipefail -c "$RPI_GUEST_SCRIPT"

  rpi_chroot_cleanup
  trap - EXIT
}

src="${IMAGES_DIR}/${UBUNTU_IMAGE}"
out="$IMAGE_BASE_OUTPUT"
[[ -f "$src" ]] || die "run ./download-images.sh first (${src} missing)"

# Ubuntu may install host kernels readable only by root. Supermin needs one
# to boot its appliance; catch this before replacing the existing base image.
if [[ "$CUSTOMIZE" == chroot ]]; then
  :  # no appliance
elif [[ -n "${SUPERMIN_KERNEL:-}" ]]; then
  [[ -r "$SUPERMIN_KERNEL" ]] || die "SUPERMIN_KERNEL is not readable: ${SUPERMIN_KERNEL}"
else
  kernel_found=0
  kernel_readable=0
  for kernel in /lib/modules/*/vmlinuz /boot/vmlinuz-*; do
    [[ -f "$kernel" ]] || continue
    kernel_found=1
    if [[ -r "$kernel" ]]; then kernel_readable=1; fi
  done
  if [[ "$kernel_found" == 1 && "$kernel_readable" == 0 ]]; then
    die "libguestfs cannot read the host kernel. On Ubuntu run: sudo chmod 0644 /boot/vmlinuz* ; then rerun this script (see README.md)."
  fi
fi

log "creating standalone working copy for ${IMAGE_TARGET}"
rm -f "$out"
if [[ "$IMAGE_FORMAT" == raw ]]; then
  xz -dc "$src" > "$out"
else
  qemu-img convert -O qcow2 "$src" "$out"
fi

if [[ "$CUSTOMIZE" == chroot ]]; then
  customize_rpi_chroot "$out"
  log "golden image ready: ${out}"
  exit 0
fi

log "installing packages into the image (needs network; takes a few minutes)"
virt-customize --network -a "$out" \
  --update \
  --install docker.io,docker-compose-v2,avahi-daemon,libnss-mdns,isc-dhcp-server,qemu-guest-agent \
  --upload "${SETUP_DIR}/base/rti-issue:/usr/local/sbin/rti-issue" \
  --chmod 0755:/usr/local/sbin/rti-issue \
  --upload "${SETUP_DIR}/base/rti-issue.service:/etc/systemd/system/rti-issue.service" \
  --upload "${SETUP_DIR}/base/rti-issue.timer:/etc/systemd/system/rti-issue.timer" \
  --run-command 'systemctl enable docker qemu-guest-agent avahi-daemon rti-issue.timer' \
  --run-command 'systemctl disable isc-dhcp-server' \
  --run-command 'sed -ri "s/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/" /etc/nsswitch.conf' \
  ${FK_MACHINE:+--run-command "$FLASH_KERNEL_CMD"} \
  --run-command 'rm -f /etc/machine-id && touch /etc/machine-id' \
  --run-command 'echo rti-base > /etc/hostname'

log "golden image ready: ${out}"
