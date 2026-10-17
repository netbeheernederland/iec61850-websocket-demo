#!/usr/bin/env bash
# Build the arm64/v8 rti-demo images (fsp, so, io) from the upstream
# iec61850-websocket repo and save them as .tar.gz archives for
# deploy-rti-demo.sh.
#
# Usage: build-rti-demo.sh [fsp] [so] [io]    (no arguments: all three)
#
# Environment:
#   RTI_IMAGE_DIR  where the archives are written (default: dist/rti-images)
#   CLONE_DIR      persistent clone of the upstream repo
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_URL="https://github.com/Netbeheer-Nederland/iec61850-websocket.git"
BRANCH="initial-refactor"
EXAMPLE_SUBDIR="examples/rti-demo"

IMAGE_BASE="netbeheer-nederland/iec61850-websocket"
ALL_IMAGES=(fsp so io)

PLATFORM="linux/arm64/v8"
BUILDX_BUILDER="rti-builder"

# Persistent clone, reused across runs instead of re-cloning every time
CLONE_DIR="${CLONE_DIR:-${TMPDIR:-/tmp}/iec61850-websocket-clone}"

# Archives are kept here for deploy-rti-demo.sh
RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images}"

usage() {
  echo "Usage: $(basename "$0") [fsp] [so] [io]   (no arguments: all)" >&2
  exit "${1:-1}"
}

# --- Arguments ----------------------------------------------------------
IMAGES=()
for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage 0 ;;
    fsp|so|io) IMAGES+=("${arg}") ;;
    *) echo "Unknown image: ${arg}" >&2; usage ;;
  esac
done
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("${ALL_IMAGES[@]}")

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

# Dockerfile and build context per image, as declared in
# examples/rti-demo/docker-compose.yml and, for io, in the IO plugin's own
# examples/rti-plugins/rpi_io/docker-compose.yaml. fsp and so build from the
# repo root (shared uv.lock, ws61850 core in src/); io builds from its plugin
# project. Paths are absolute: buildx resolves -f against the shell's cwd,
# not the build context.
EXAMPLE_DIR="${CLONE_DIR}/${EXAMPLE_SUBDIR}"
IO_PLUGIN_DIR="${CLONE_DIR}/examples/rti-plugins/rpi_io"
declare -A DOCKERFILE=(
  [fsp]="${EXAMPLE_DIR}/modules/fsp/docker/Dockerfile"
  [so]="${EXAMPLE_DIR}/modules/so/docker/Dockerfile"
  [io]="${IO_PLUGIN_DIR}/docker/Dockerfile"
)
declare -A CONTEXT=(
  [fsp]="${CLONE_DIR}"
  [so]="${CLONE_DIR}"
  [io]="${IO_PLUGIN_DIR}"
)

# --- Register QEMU emulation for cross-arch builds (idempotent) ------------
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  echo "Registering QEMU binfmt handlers for cross-arch builds..."
  docker run --privileged --rm tonistiigi/binfmt --install arm64
fi

# --- Set up a buildx builder capable of multi-arch builds ------------------
if ! docker buildx inspect "${BUILDX_BUILDER}" >/dev/null 2>&1; then
  echo "Creating buildx builder ${BUILDX_BUILDER}..."
  docker buildx create --name "${BUILDX_BUILDER}" --driver docker-container
fi
docker buildx use "${BUILDX_BUILDER}"
docker buildx inspect --bootstrap >/dev/null

# --- Build and export arm64/v8 images (the only arch the pis run) ----------
mkdir -p "${RTI_IMAGE_DIR}"

for image in "${IMAGES[@]}"; do
  tag="${IMAGE_BASE}/rti-${image}"
  tar="${RTI_IMAGE_DIR}/rti-${image}.tar.gz"

  echo "Building ${tag} for ${PLATFORM}..."
  docker buildx build --platform "${PLATFORM}" \
    -f "${DOCKERFILE[${image}]}" -t "${tag}" --load "${CONTEXT[${image}]}"

  # Write to a temp file first, so an interrupted export never leaves a
  # truncated archive behind for deploy-rti-demo.sh to ship.
  echo "Exporting ${tag} to ${tar}..."
  docker save "${tag}" | gzip > "${tar}.partial"
  mv "${tar}.partial" "${tar}"
done

echo "Images in ${RTI_IMAGE_DIR}:"
ls -lh "${RTI_IMAGE_DIR}"
echo "Next: scripts/deploy-rti-demo.sh [machine ...]"
