#!/usr/bin/env bash
# Build rti-demo images from the upstream iec61850-websocket repo, load them
# into the local Docker and save them as .tar.gz archives for
# deploy-rti-demo.sh.
#
# Usage: build-rti-demo.sh [--platform PLATFORM] [fsp] [so] [bff] [hmi]
#                          [plugins] [PLUGIN ...]
#        (no images: all of them, the base images and the plugins)
#
#   --platform PLATFORM   target platform (default: linux/arm64/v8, the Pis).
#                         linux/amd64 builds the images for the setup/ VM
#                         fleet, then run setup/build-tarballs.sh.
#   fsp so bff hmi        the base images, built as rti-<image>
#   plugins               every plugin in upstream examples/rti-plugins/ that
#                         has a docker/Dockerfile: dr-panel and dr-leds
#   PLUGIN                one of them, by folder name with - for _ (dr-leds)
#
# A plugin is built under its own name (dr-panel, not rti-dr-panel), as in
# upstream's compose files. Every archive is saved as <name>.tar.gz in the
# archive directory.
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

IMAGE_BASE="netbeheernederland/iec61850-websocket"
DEFAULT_IMAGES=(fsp so bff hmi plugins)
PLUGINS_SUBDIR="examples/rti-plugins"

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
    -*) echo "Unknown option: $1" >&2; usage ;;
    # Plugin names are only known after the clone; checked there.
    *) IMAGES+=("$1") ;;
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

# Dockerfile and build context per base image, as declared in
# examples/rti-demo/docker-compose.yml. fsp, so and bff build from the repo
# root (shared uv.lock, ws61850 core in src/); hmi builds from its module.
# Paths are absolute: buildx resolves -f against the shell's cwd, not the
# build context.
EXAMPLE_DIR="${CLONE_DIR}/${EXAMPLE_SUBDIR}"
declare -A DOCKERFILE=(
  [fsp]="${EXAMPLE_DIR}/modules/fsp/docker/Dockerfile"
  [so]="${EXAMPLE_DIR}/modules/so/docker/Dockerfile"
  [bff]="${EXAMPLE_DIR}/modules/bff/docker/Dockerfile"
  [hmi]="${EXAMPLE_DIR}/modules/hmi/docker/Dockerfile"
)
declare -A CONTEXT=(
  [fsp]="${CLONE_DIR}"
  [so]="${CLONE_DIR}"
  [bff]="${CLONE_DIR}"
  [hmi]="${EXAMPLE_DIR}/modules/hmi"
)
# The hmi's optional build-time BFF address, as in the upstream compose file.
declare -A BUILD_ARGS=(
  [hmi]="--build-arg VITE_BFF_HOST=${VITE_BFF_HOST:-} --build-arg VITE_BFF_PORT=${VITE_BFF_PORT:-}"
)

# The plugins (upstream decisions 0028-0030): each its own project with
# docker/Dockerfile, built from the project folder, e.g. dr_panel and dr_leds.
# dr-panel's build args (PI_USER, GPIO_GID, ...) keep their defaults: the
# role compose files run it privileged.
PLUGINS=()
for dir in "${CLONE_DIR}/${PLUGINS_SUBDIR}"/*/; do
  dir="${dir%/}"
  name="$(basename "${dir}")"
  [ -f "${dir}/docker/Dockerfile" ] || continue
  plugin="${name//_/-}"
  PLUGINS+=("${plugin}")
  DOCKERFILE[${plugin}]="${dir}/docker/Dockerfile"
  CONTEXT[${plugin}]="${dir}"
done

# Expand "plugins" and check every name now that the plugins are known
SELECTED=()
for image in "${IMAGES[@]}"; do
  if [ "${image}" = plugins ]; then
    SELECTED+=("${PLUGINS[@]}")
  elif [ -n "${DOCKERFILE[${image}]+x}" ]; then
    SELECTED+=("${image}")
  else
    echo "Unknown image: ${image} (known: fsp so bff hmi plugins ${PLUGINS[*]})" >&2
    exit 1
  fi
done
# Each image once, in the order given
declare -A seen=()
IMAGES=()
for image in "${SELECTED[@]}"; do
  [ -n "${seen[${image}]+x}" ] && continue
  seen[${image}]=1
  IMAGES+=("${image}")
done

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

is_plugin() {
  local p
  for p in "${PLUGINS[@]}"; do [ "${p}" = "$1" ] && return 0; done
  return 1
}

for image in "${IMAGES[@]}"; do
  # Base images are rti-<image>; plugins keep their own name
  name="rti-${image}"
  is_plugin "${image}" && name="${image}"
  tag="${IMAGE_BASE}/${name}"
  tar="${RTI_IMAGE_DIR}/${name}.tar.gz"

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
