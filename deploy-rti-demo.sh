#!/usr/bin/env bash
set -euo pipefail

# --- Configuration -----------------------------------------------------
REPO_URL="https://github.com/Netbeheer-Nederland/iec61850-websocket.git"
BRANCH="initial-refactor"
EXAMPLE_SUBDIR="examples/rti-demo"

IMAGE_FSP="rti-demo-rti-fsp"
IMAGE_SO="rti-demo-rti-so"
IMAGE_IO="rti-demo-rti-io"

MACHINE1_DEST="pi@192.168.100.97:pi"       # receives: so, io
MACHINE2_DEST="pi2@192.168.100.98:/pi"     # receives: fsp, io

# --- Work in an isolated temp directory --------------------------------
WORKDIR="$(mktemp -d -t rti-demo-XXXXXX)"
echo "Using temporary directory: ${WORKDIR}"

cleanup() {
  echo "Cleaning up ${WORKDIR}"
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# --- Clone and checkout --------------------------------------------------
git clone "${REPO_URL}" "${WORKDIR}/iec61850-websocket"
cd "${WORKDIR}/iec61850-websocket"
git checkout "${BRANCH}"

cd "${EXAMPLE_SUBDIR}"

# --- Build images ---------------------------------------------------------
docker compose build

# --- Export images to tar.gz ----------------------------------------------
EXPORT_DIR="${WORKDIR}/exports"
mkdir -p "${EXPORT_DIR}"

FSP_TAR="${EXPORT_DIR}/${IMAGE_FSP}.tar.gz"
SO_TAR="${EXPORT_DIR}/${IMAGE_SO}.tar.gz"
IO_TAR="${EXPORT_DIR}/${IMAGE_IO}.tar.gz"

echo "Exporting ${IMAGE_FSP}..."
docker save "${IMAGE_FSP}" | gzip > "${FSP_TAR}"

echo "Exporting ${IMAGE_SO}..."
docker save "${IMAGE_SO}" | gzip > "${SO_TAR}"

echo "Exporting ${IMAGE_IO}..."
docker save "${IMAGE_IO}" | gzip > "${IO_TAR}"

# --- Copy images to target machines ----------------------------------------
# machine1 gets: so, io
echo "Copying ${IMAGE_SO} and ${IMAGE_IO} to machine1 (${MACHINE1_DEST})..."
scp "${SO_TAR}" "${IO_TAR}" "${MACHINE1_DEST}"

# machine2 gets: fsp, io
echo "Copying ${IMAGE_FSP} and ${IMAGE_IO} to machine2 (${MACHINE2_DEST})..."
scp "${FSP_TAR}" "${IO_TAR}" "${MACHINE2_DEST}"

echo "Done."
