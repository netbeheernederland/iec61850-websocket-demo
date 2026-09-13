#!/usr/bin/env bash
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_URL="https://github.com/Netbeheer-Nederland/iec61850-websocket.git"
BRANCH="initial-refactor"
EXAMPLE_SUBDIR="examples/rti-demo"

IMAGE_FSP="rti-demo-rti-fsp"
IMAGE_SO="rti-demo-rti-so"
IMAGE_IO="rti-demo-rti-io"

IMAGE_BASE="netbeheer-nederland/iec61850-websocket"
IMAGE_FSP_TAGGED="${IMAGE_BASE}/rti-fsp"
IMAGE_SO_TAGGED="${IMAGE_BASE}/rti-so"
IMAGE_IO_TAGGED="${IMAGE_BASE}/rti-io"

# Role modules (local to this repo), providing each machine's docker-compose.yml
SO_MODULE_COMPOSE="${REPO_ROOT}/modules/so/docker-compose.yml"
FSP01_MODULE_COMPOSE="${REPO_ROOT}/modules/fsp01/docker-compose.yml"

# Script run on the target machine to load the image archives and start compose
LOAD_AND_START_SCRIPT="${SCRIPT_DIR}/load-and-start.sh"

MACHINE_SO_DEST="pi@192.168.100.97:rti-demo"       # role: so    -- receives: so, io, docker-compose.yml
MACHINE_FSP01_DEST="pi@192.168.100.98:rti-demo"    # role: fsp01 -- receives: fsp, io, docker-compose.yml

# Persistent clone, reused across runs instead of re-cloning every time
CLONE_DIR="${CLONE_DIR:-${TMPDIR:-/tmp}/iec61850-websocket-clone}"

# --- Export directory (ephemeral) ---------------------------------------
EXPORT_DIR="$(mktemp -d -t rti-demo-exports-XXXXXX)"
echo "Using export directory: ${EXPORT_DIR}"

cleanup() {
  echo "Cleaning up ${EXPORT_DIR}"
  rm -rf "${EXPORT_DIR}"
}
trap cleanup EXIT

# --- Clone (first run) or update (subsequent runs) -----------------------
if [ -d "${CLONE_DIR}/.git" ]; then
  echo "Reusing existing clone at ${CLONE_DIR}, updating..."
  git -C "${CLONE_DIR}" fetch origin "${BRANCH}"
  git -C "${CLONE_DIR}" checkout "${BRANCH}"
  git -C "${CLONE_DIR}" reset --hard "origin/${BRANCH}"
else
  echo "No existing clone found, cloning into ${CLONE_DIR}..."
  git clone "${REPO_URL}" "${CLONE_DIR}"
  git -C "${CLONE_DIR}" checkout "${BRANCH}"
fi

cd "${CLONE_DIR}/${EXAMPLE_SUBDIR}"

# --- Build images ---------------------------------------------------------
docker compose build

# --- Tag images with the netbeheer-nederland base name --------------------
docker tag "${IMAGE_FSP}" "${IMAGE_FSP_TAGGED}"
docker tag "${IMAGE_SO}" "${IMAGE_SO_TAGGED}"
docker tag "${IMAGE_IO}" "${IMAGE_IO_TAGGED}"

# --- Export images to tar.gz ----------------------------------------------
FSP_TAR="${EXPORT_DIR}/${IMAGE_FSP}.tar.gz"
SO_TAR="${EXPORT_DIR}/${IMAGE_SO}.tar.gz"
IO_TAR="${EXPORT_DIR}/${IMAGE_IO}.tar.gz"

echo "Exporting ${IMAGE_FSP_TAGGED}..."
docker save "${IMAGE_FSP_TAGGED}" | gzip > "${FSP_TAR}"

echo "Exporting ${IMAGE_SO_TAGGED}..."
docker save "${IMAGE_SO_TAGGED}" | gzip > "${SO_TAR}"

echo "Exporting ${IMAGE_IO_TAGGED}..."
docker save "${IMAGE_IO_TAGGED}" | gzip > "${IO_TAR}"

# --- Copy images, role compose file and load-and-start script to target machines ------------------
# so machine gets: so, io, modules/so/docker-compose.yml, load-and-start.sh
echo "Copying ${IMAGE_SO}, ${IMAGE_IO}, so docker-compose.yml and load-and-start.sh to so machine (${MACHINE_SO_DEST})..."
scp "${SO_TAR}" "${IO_TAR}" "${SO_MODULE_COMPOSE}" "${LOAD_AND_START_SCRIPT}" "${MACHINE_SO_DEST}"

# fsp01 machine gets: fsp, io, modules/fsp01/docker-compose.yml, load-and-start.sh
echo "Copying ${IMAGE_FSP}, ${IMAGE_IO}, fsp01 docker-compose.yml and load-and-start.sh to fsp01 machine (${MACHINE_FSP01_DEST})..."
scp "${FSP_TAR}" "${IO_TAR}" "${FSP01_MODULE_COMPOSE}" "${LOAD_AND_START_SCRIPT}" "${MACHINE_FSP01_DEST}"

echo "On each target machine, run: chmod +x load-and-start.sh && ./load-and-start.sh"

echo "Done."
