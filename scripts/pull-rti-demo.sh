#!/usr/bin/env bash
# Pull the arm64/v8 rti-demo base images (fsp, so) from the GitHub Container
# Registry and save them as .tar.gz archives for deploy-rti-demo.sh, in place
# of building them with build-rti-demo.sh. See docs/docker-images-github.md.
# The plugins dr-panel and dr-leds are published too, but not pulled here:
# build them with build-rti-demo.sh plugins. (The published rti-io is the IO server from
# before it became the plugin dr_panel; the role compose files don't use it.)
#
# Usage: pull-rti-demo.sh [--tag TAG] [fsp] [so]   (no images: both)
#
#   --tag TAG   registry tag to pull, e.g. sha-1a2b3c4 to pin a build
#               (default: RTI_TAG, else latest)
#
# The images are re-tagged to the local names the compose files use
# (netbeheernederland/iec61850-websocket/rti-<image>:latest) before saving,
# so deploy-rti-demo.sh and load-and-start.sh work unchanged.
#
# Private packages need a docker login first:
#   echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-user> --password-stdin
#
# Environment:
#   RTI_REGISTRY   registry and namespace to pull from
#                  (default: ghcr.io/netbeheernederland/iec61850-websocket)
#   RTI_TAG        default for --tag
#   RTI_IMAGE_DIR  where the archives are written (default: dist/rti-images-arm64)
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RTI_REGISTRY="${RTI_REGISTRY:-ghcr.io/netbeheernederland/iec61850-websocket}"
TAG="${RTI_TAG:-latest}"

# Local name, as used by the compose files and build-rti-demo.sh
IMAGE_BASE="netbeheernederland/iec61850-websocket"
ALL_IMAGES=(fsp so)

PLATFORM="linux/arm64/v8"

# Archives are kept here for deploy-rti-demo.sh
RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images-arm64}"

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
    --tag)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--tag needs a value" >&2
        usage
      fi
      TAG="$2"; shift ;;
    fsp|so) IMAGES+=("$1") ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=("${ALL_IMAGES[@]}")

# docker save only takes --platform on newer Docker versions; it is needed
# with the containerd image store, where the pulled arm64 content is not the
# host's platform.
SAVE_ARGS=()
if docker save --help 2>/dev/null | grep -q -- '--platform'; then
  SAVE_ARGS=(--platform "${PLATFORM}")
fi

# --- Pull, re-tag and export ------------------------------------------------
mkdir -p "${RTI_IMAGE_DIR}"

for image in "${IMAGES[@]}"; do
  remote="${RTI_REGISTRY}/rti-${image}:${TAG}"
  local_tag="${IMAGE_BASE}/rti-${image}:latest"
  tar="${RTI_IMAGE_DIR}/rti-${image}.tar.gz"

  echo "Pulling ${remote} for ${PLATFORM}..."
  if ! docker pull --platform "${PLATFORM}" "${remote}"; then
    echo "Could not pull ${remote}." >&2
    echo "For a private package, log in first: docker login ghcr.io (token with read:packages)" >&2
    exit 1
  fi

  # Catch an amd64-only image here rather than as 'exec format error' on a Pi
  arch="$(docker image inspect --format '{{.Architecture}}' "${remote}")"
  if [ "${arch}" != "arm64" ]; then
    echo "${remote} is ${arch}, not arm64: the Pis cannot run it" >&2
    exit 1
  fi

  echo "Tagging ${remote} as ${local_tag}..."
  docker tag "${remote}" "${local_tag}"

  # Write to a temp file first, so an interrupted export never leaves a
  # truncated archive behind for deploy-rti-demo.sh to ship.
  echo "Exporting ${local_tag} to ${tar}..."
  docker save "${SAVE_ARGS[@]}" "${local_tag}" | gzip > "${tar}.partial"
  mv "${tar}.partial" "${tar}"
done

echo "Images in ${RTI_IMAGE_DIR}:"
ls -lh "${RTI_IMAGE_DIR}"
echo "Next: scripts/build-rti-demo.sh plugins (if not done), then scripts/deploy-rti-demo.sh [machine ...]"
