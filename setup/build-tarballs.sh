#!/usr/bin/env bash
# `docker save` every image the fleet needs into images/*.tar so each node's
# cloud-init can `docker load` them offline. Run this after you have built the
# rti-demo_* images locally (the same ones docker-compose.yml references).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_config
need docker

mkdir -p "$IMAGES_DIR"

# union of every role's tarball list
declare -A want=()
for role in "${!ROLE_TARBALLS[@]}"; do
  for tb in ${ROLE_TARBALLS[$role]}; do want[$tb]=1; done
done

missing=0
for tb in "${!want[@]}"; do
  ref="${IMAGE_REF[$tb]:-}"
  [[ -n "$ref" ]] || die "no IMAGE_REF entry for tarball '${tb}' (check roles.env)"
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    warn "image ${ref} not found locally - build it first; skipping ${tb}.tar"
    missing=1
    continue
  fi
  log "saving ${ref} -> images/${tb}.tar"
  docker save "$ref" -o "${IMAGES_DIR}/${tb}.tar"
done

[[ $missing -eq 0 ]] || die "one or more images were missing - see warnings above"
log "done"
