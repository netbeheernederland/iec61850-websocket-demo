#!/usr/bin/env bash
# Define the libvirt network, then import each node as a domain. The edge node
# is booted first and we wait for it to answer before starting the rest, since
# it serves DHCP (and mDNS is only useful once peers have leases).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need virsh; need virt-install

# 1. libvirt network -----------------------------------------------------
if ! virsh net-info "$LIBVIRT_NET" >/dev/null 2>&1; then
  log "defining libvirt network ${LIBVIRT_NET}"
  virsh net-define "${SETUP_DIR}/libvirt/${LIBVIRT_NET}.xml" >/dev/null
fi
virsh net-start     "$LIBVIRT_NET" >/dev/null 2>&1 || true
virsh net-autostart "$LIBVIRT_NET" >/dev/null 2>&1 || true

define_node() {
  local d="${BUILD_DIR}/${NODE_NAME}"
  [[ -f "${d}/${NODE_NAME}.qcow2" ]] || die "run ./make-disks.sh first (${NODE_NAME})"
  # shellcheck disable=SC1091
  source "${d}/spec"
  if virsh dominfo "$NODE_NAME" >/dev/null 2>&1; then
    warn "domain ${NODE_NAME} already exists - skipping (./destroy.sh to reset)"
    return
  fi
  log "[${NODE_NAME}] virt-install  ${VCPUS} vcpu / ${RAM_MB} MB / ${MAC}"
  virt-install \
    --name "$NODE_NAME" \
    --memory "$RAM_MB" --vcpus "$VCPUS" --cpu host-passthrough \
    --import \
    --disk "path=${d}/${NODE_NAME}.qcow2,format=qcow2,bus=virtio" \
    --disk "path=${d}/seed.iso,device=cdrom,readonly=on" \
    --network "network=${LIBVIRT_NET},mac=${MAC},model=virtio" \
    --osinfo detect=on,require=off \
    --graphics none --noautoconsole
}

wait_for_ping() {
  local ip="$1" i
  log "waiting for ${ip} ..."
  for i in $(seq 1 90); do
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && { log "${ip} is up"; return 0; }
    sleep 5
  done
  die "timed out waiting for ${ip}"
}

# 2. edge first --------------------------------------------------------
for line in "${NODES[@]}"; do
  read -r NODE_NAME NODE_ROLE NODE_IP NODE_EXTRA <<<"$line"
  [[ "$NODE_ROLE" == edge ]] || continue
  define_node
  wait_for_ping "$EDGE_IP"
  log "letting dhcpd settle"; sleep 10
done

# 3. everyone else ---------------------------------------------------
for line in "${NODES[@]}"; do
  read -r NODE_NAME NODE_ROLE NODE_IP NODE_EXTRA <<<"$line"
  [[ "$NODE_ROLE" == edge ]] && continue
  define_node
done

log "domains defined:"
virsh list --all
log "consoles: virsh console <name>   |   cloud-init log: ssh ${VM_USER}@<ip> 'sudo cloud-init status --wait'"
