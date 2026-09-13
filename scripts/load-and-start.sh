#!/usr/bin/env bash
# Runs on the target machine (so / fsp01), in the directory that received
# the *.tar.gz image archives and docker-compose.yml from deploy-rti-demo.sh.
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
