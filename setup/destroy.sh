#!/usr/bin/env bash
# Tear down every domain in nodes.env (and the libvirt network unless
# --keep-network). Rendered artifacts under build/ are left in place.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need virsh

keep_net=0
[[ "${1:-}" == "--keep-network" ]] && keep_net=1

for line in "${NODES[@]}"; do
  read -r name _ <<<"$line"
  virsh dominfo "$name" >/dev/null 2>&1 || continue
  log "destroying ${name}"
  virsh destroy  "$name" >/dev/null 2>&1 || true
  virsh undefine "$name" --nvram >/dev/null 2>&1 || virsh undefine "$name" >/dev/null 2>&1 || true
done

if [[ $keep_net -eq 0 ]] && virsh net-info "$LIBVIRT_NET" >/dev/null 2>&1; then
  log "removing libvirt network ${LIBVIRT_NET}"
  virsh net-destroy  "$LIBVIRT_NET" >/dev/null 2>&1 || true
  virsh net-undefine "$LIBVIRT_NET" >/dev/null 2>&1 || true
fi
log "done"
