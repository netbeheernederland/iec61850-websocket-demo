#!/usr/bin/env bash
# Runs on the target machine (any role), in the directory that received
# the *.tar.gz image archives, docker-compose.yml and .env staged by
# stage-rti-role.sh: copied by deploy-rti-demo.sh, or from the boot partition
# on first boot (setup/pi-user-data.sh --role).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

shopt -s nullglob
TARS=(*.tar.gz)
shopt -u nullglob

if [ ${#TARS[@]} -eq 0 ]; then
  echo "No .tar.gz image archives found in ${SCRIPT_DIR}" >&2
  exit 1
fi

for tar in "${TARS[@]}"; do
  echo "Loading ${tar}..."
  gunzip -c "${tar}" | docker load
done

echo "Starting docker compose..."
docker compose up -d

echo "Done."
