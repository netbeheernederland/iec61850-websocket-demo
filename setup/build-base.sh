#!/usr/bin/env bash
# Bake a golden image: Ubuntu cloud image + docker, avahi/nss-mdns and
# isc-dhcp-server preinstalled, so per-node cloud-init never has to touch apt
# (fast, deterministic, works even if the VM has no outbound DNS at boot).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need qemu-img; need virt-customize

src="${IMAGES_DIR}/${UBUNTU_IMAGE}"
out="${IMAGES_DIR}/base-rti.qcow2"
[[ -f "$src" ]] || die "run ./download-images.sh first (${src} missing)"

log "creating standalone working copy (native ~3.5G virtual size)"
rm -f "$out"
qemu-img convert -O qcow2 "$src" "$out"

log "installing packages into the image (needs network; takes a few minutes)"
virt-customize --network -a "$out" \
  --update \
  --install docker.io,docker-compose-v2,avahi-daemon,libnss-mdns,isc-dhcp-server,qemu-guest-agent \
  --run-command 'systemctl enable docker qemu-guest-agent avahi-daemon' \
  --run-command 'systemctl disable isc-dhcp-server' \
  --run-command 'sed -ri "s/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/" /etc/nsswitch.conf' \
  --run-command 'rm -f /etc/machine-id && touch /etc/machine-id' \
  --run-command 'echo rti-base > /etc/hostname'

log "golden image ready: ${out}"
