#!/usr/bin/env bash
# Tag locally built rti-demo images (from build-rti-demo.sh) with the GitHub
# Container Registry name, so they can be pushed by hand. See
# docs/docker-images-github.md.
#
# Usage: retag-images.sh [--tag TAG] [fsp] [so] [bff] [hmi] [dr-panel] [dr-leds]
#        (no images: every one of them present locally)
#
# Base images are rti-<image>; the plugins keep their own name (dr-panel).
#
#   --tag TAG   extra registry tag next to latest, e.g. sha-1a2b3c4
#
# Nothing is pushed; the script prints the docker push commands. Pushing
# needs a docker login with a token that has write:packages:
#   echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-user> --password-stdin
#
# Environment:
#   RTI_REGISTRY   registry and namespace to tag for
#                  (default: ghcr.io/netbeheernederland/iec61850-websocket)
set -euo pipefail

# --- Configuration -----------------------------------------------------
RTI_REGISTRY="${RTI_REGISTRY:-ghcr.io/netbeheernederland/iec61850-websocket}"

# Local name, as used by the compose files and build-rti-demo.sh
IMAGE_BASE="netbeheernederland/iec61850-websocket"
ALL_IMAGES=(fsp so bff hmi dr-panel dr-leds)

# The image's name: rti-<image> for a base image, the plugin's own name
image_name() {
  case "$1" in
    dr-*) echo "$1" ;;
    *)    echo "rti-$1" ;;
  esac
}

usage() {
  # The header comment, from Usage: to the end
  sed -n '/^# Usage:/,/^set -e/{/^set -e/d;s/^# \{0,1\}//p;}' "$0" >&2
  exit "${1:-1}"
}

# --- Arguments ----------------------------------------------------------
EXTRA_TAG=""
IMAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --tag)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--tag needs a value" >&2
        usage
      fi
      EXTRA_TAG="$2"; shift ;;
    fsp|so|bff|hmi|dr-panel|dr-leds) IMAGES+=("$1") ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
  shift
done

# Without arguments, take whichever images are present; named images must be.
if [ ${#IMAGES[@]} -eq 0 ]; then
  for image in "${ALL_IMAGES[@]}"; do
    if docker image inspect "${IMAGE_BASE}/$(image_name "${image}"):latest" >/dev/null 2>&1; then
      IMAGES+=("${image}")
    fi
  done
  if [ ${#IMAGES[@]} -eq 0 ]; then
    echo "No ${IMAGE_BASE}/{rti-*,dr-*}:latest images found; run build-rti-demo.sh first" >&2
    exit 1
  fi
fi

# --- Re-tag -------------------------------------------------------------
PUSH=()
for image in "${IMAGES[@]}"; do
  name="$(image_name "${image}")"
  local_tag="${IMAGE_BASE}/${name}:latest"
  if ! docker image inspect "${local_tag}" >/dev/null 2>&1; then
    echo "${local_tag} not found; run build-rti-demo.sh ${image} first" >&2
    exit 1
  fi
  arch="$(docker image inspect --format '{{.Architecture}}' "${local_tag}")"

  for tag in latest ${EXTRA_TAG}; do
    remote="${RTI_REGISTRY}/${name}:${tag}"
    echo "Tagging ${local_tag} (${arch}) as ${remote}..."
    docker tag "${local_tag}" "${remote}"
    PUSH+=("${remote}")
  done
done

echo
echo "To push:"
for remote in "${PUSH[@]}"; do
  echo "  docker push ${remote}"
done
