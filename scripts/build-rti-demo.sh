#!/usr/bin/env bash
# Build rti-demo images from the upstream iec61850-websocket repo, load them
# into the local Docker and save them as .tar.gz archives for
# deploy-rti-demo.sh.
#
# Usage: build-rti-demo.sh [--platform PLATFORM] [fsp] [so] [io] [bff] [hmi]
#        (no images: fsp, so and io, the Pi images)
#
#   --platform PLATFORM   target platform (default: linux/arm64/v8, the Pis).
#                         linux/amd64 builds the images for the setup/ VM
#                         fleet: bff hmi so fsp, then setup/build-tarballs.sh.
#
# Environment:
#   RTI_IMAGE_DIR  where the archives are written
#                  (default: dist/rti-images-<arch>, e.g. dist/rti-images-arm64)
#   CLONE_DIR      persistent clone of the upstream repo
#   VITE_BFF_HOST, VITE_BFF_PORT
#                  optional BFF address baked into the hmi bundle
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_URL="https://github.com/Netbeheer-Nederland/iec61850-websocket.git"
BRANCH="initial-refactor"
EXAMPLE_SUBDIR="examples/rti-demo"

IMAGE_BASE="netbeheer-nederland/iec61850-websocket"
DEFAULT_IMAGES=(fsp so io)

PLATFORM="linux/arm64/v8"
BUILDX_BUILDER="rti-builder"

# Persistent clone, reused across runs instead of re-cloning every time
CLONE_DIR="${CLONE_DIR:-${TMPDIR:-/tmp}/iec61850-websocket-clone}"

usage() {
  # The header comment, from Usage: to the end
  sed -n '/^# Usage:/,/^set -e/{/^set -e/d;s/^# \{0,1\}//p;}' "$0" >&2
  exit "${1:-1}"
}

# --- Arguments ----------------------------------------------------------
IMAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --platform)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--platform needs a value" >&2
        usage
      fi
      PLATFORM="$2"; shift ;;
    fsp|so|io|bff|hmi) IMAGES+=("$1") ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("${DEFAULT_IMAGES[@]}")

# Archives are kept per architecture (linux/arm64/v8 -> arm64), so builds
# for different platforms never replace each other's archives.
ARCH="${PLATFORM#*/}"; ARCH="${ARCH%%/*}"
RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images-${ARCH}}"

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
# examples/rti-plugins/rpi_io/docker-compose.yaml. fsp, so and bff build from
# the repo root (shared uv.lock, ws61850 core in src/); hmi builds from its
# module and io from its plugin project. Paths are absolute: buildx resolves
# -f against the shell's cwd, not the build context.
EXAMPLE_DIR="${CLONE_DIR}/${EXAMPLE_SUBDIR}"
IO_PLUGIN_DIR="${CLONE_DIR}/examples/rti-plugins/rpi_io"
declare -A DOCKERFILE=(
  [fsp]="${EXAMPLE_DIR}/modules/fsp/docker/Dockerfile"
  [so]="${EXAMPLE_DIR}/modules/so/docker/Dockerfile"
  [io]="${IO_PLUGIN_DIR}/docker/Dockerfile"
  [bff]="${EXAMPLE_DIR}/modules/bff/docker/Dockerfile"
  [hmi]="${EXAMPLE_DIR}/modules/hmi/docker/Dockerfile"
)
declare -A CONTEXT=(
  [fsp]="${CLONE_DIR}"
  [so]="${CLONE_DIR}"
  [io]="${IO_PLUGIN_DIR}"
  [bff]="${CLONE_DIR}"
  [hmi]="${EXAMPLE_DIR}/modules/hmi"
)
# The hmi's optional build-time BFF address, as in the upstream compose file.
declare -A BUILD_ARGS=(
  [hmi]="--build-arg VITE_BFF_HOST=${VITE_BFF_HOST:-} --build-arg VITE_BFF_PORT=${VITE_BFF_PORT:-}"
)

# --- Register QEMU emulation for cross-arch builds (idempotent) ------------
if [[ "${PLATFORM}" == linux/arm64* && "$(uname -m)" != aarch64 ]] \
    && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
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

# --- Build, load and export the images ------------------------------------
mkdir -p "${RTI_IMAGE_DIR}"

for image in "${IMAGES[@]}"; do
  tag="${IMAGE_BASE}/rti-${image}"
  tar="${RTI_IMAGE_DIR}/rti-${image}.tar.gz"

  echo "Building ${tag} for ${PLATFORM}..."
  # shellcheck disable=SC2086  # BUILD_ARGS is a list of flags
  docker buildx build --platform "${PLATFORM}" ${BUILD_ARGS[${image}]:-} \
    -f "${DOCKERFILE[${image}]}" -t "${tag}" --load "${CONTEXT[${image}]}"

  # Write to a temp file first, so an interrupted export never leaves a
  # truncated archive behind for deploy-rti-demo.sh to ship.
  echo "Exporting ${tag} to ${tar}..."
  docker save "${tag}" | gzip > "${tar}.partial"
  mv "${tar}.partial" "${tar}"
done

echo "Images in ${RTI_IMAGE_DIR}:"
ls -lh "${RTI_IMAGE_DIR}"
case "${PLATFORM}" in
  linux/arm64*) echo "Next: scripts/deploy-rti-demo.sh [machine ...]" ;;
  *)            echo "Images loaded locally; for the VM fleet next run: setup/build-tarballs.sh" ;;
esac
