#!/usr/bin/env bash
# Push locally built rti-demo images (from build-rti-demo.sh) to the GitHub
# Container Registry by hand. See docs/docker-images-github.md, section 4.
#
# Usage: push-rti-demo.sh [--tag TAG] [--no-latest] [--arch ARCH] [--dry-run]
#                         [fsp] [so] [bff] [hmi] [dr-panel] [dr-leds]
#        (no images: every one of them present locally)
#
# Base images are rti-<image>; the plugins keep their own name (dr-panel).
# Each image is tagged with its GHCR name and pushed.
#
#   --tag TAG     extra registry tag next to latest, e.g. sha-1a2b3c4
#   --no-latest   push only the --tag tag, leave latest in the registry alone
#   --arch ARCH   architecture every image must have (default: arm64, the
#                 Pis). Stops before pushing anything if one differs, so an
#                 amd64 build never replaces the Pis' latest.
#   --dry-run     check and tag, print the push commands, push nothing
#
# Pushing needs a docker login with a token that has write:packages:
#   echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-user> --password-stdin
#   gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
#
# Environment:
#   RTI_REGISTRY   registry and namespace to push to
#                  (default: ghcr.io/netbeheernederland/iec61850-websocket)
set -euo pipefail

# --- Configuration -----------------------------------------------------
RTI_REGISTRY="${RTI_REGISTRY:-ghcr.io/netbeheernederland/iec61850-websocket}"
REGISTRY_HOST="${RTI_REGISTRY%%/*}"

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

need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    echo "$1 needs a value" >&2
    usage
  fi
}

# --- Arguments ----------------------------------------------------------
EXTRA_TAG=""
LATEST=1
ARCH="arm64"
DRY_RUN=0
IMAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --tag)       need_value "$@"; EXTRA_TAG="$2"; shift ;;
    --arch)      need_value "$@"; ARCH="$2"; shift ;;
    --no-latest) LATEST=0 ;;
    --dry-run)   DRY_RUN=1 ;;
    fsp|so|bff|hmi|dr-panel|dr-leds) IMAGES+=("$1") ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
  shift
done

TAGS=()
[ "${LATEST}" -eq 1 ] && TAGS+=(latest)
[ -n "${EXTRA_TAG}" ] && TAGS+=("${EXTRA_TAG}")
if [ ${#TAGS[@]} -eq 0 ]; then
  echo "--no-latest needs --tag TAG: there is nothing to push otherwise" >&2
  exit 1
fi

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

# --- Check every image before pushing any ----------------------------------
for image in "${IMAGES[@]}"; do
  local_tag="${IMAGE_BASE}/$(image_name "${image}"):latest"
  if ! docker image inspect "${local_tag}" >/dev/null 2>&1; then
    echo "${local_tag} not found; run build-rti-demo.sh ${image} first" >&2
    exit 1
  fi
  arch="$(docker image inspect --format '{{.Architecture}}' "${local_tag}")"
  if [ "${arch}" != "${ARCH}" ]; then
    echo "${local_tag} is ${arch}, not ${ARCH}; rebuild it or pass --arch ${arch}" >&2
    exit 1
  fi
done

# A missing login only shows up as 'denied' halfway through the pushes
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
if [ "${DRY_RUN}" -eq 0 ] \
    && ! grep -qs "\"${REGISTRY_HOST}\"" "${DOCKER_CONFIG_FILE}"; then
  echo "Not logged in to ${REGISTRY_HOST}. Log in with a token that has write:packages:" >&2
  echo "  echo \"\${GHCR_TOKEN}\" | docker login ${REGISTRY_HOST} -u <github-user> --password-stdin" >&2
  exit 1
fi

# --- Tag and push ------------------------------------------------------------
PUSHED=()
for image in "${IMAGES[@]}"; do
  name="$(image_name "${image}")"
  local_tag="${IMAGE_BASE}/${name}:latest"

  for tag in "${TAGS[@]}"; do
    remote="${RTI_REGISTRY}/${name}:${tag}"
    echo "Tagging ${local_tag} (${ARCH}) as ${remote}..."
    docker tag "${local_tag}" "${remote}"

    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "  (dry run) docker push ${remote}"
      continue
    fi
    echo "Pushing ${remote}..."
    if ! docker push "${remote}"; then
      echo "Could not push ${remote}." >&2
      echo "Check the token has write:packages and is SSO-authorised for the organisation." >&2
      exit 1
    fi
    PUSHED+=("${remote}")
  done
done

[ "${DRY_RUN}" -eq 1 ] && exit 0

echo
echo "Pushed:"
printf '  %s\n' "${PUSHED[@]}"
echo
echo "A package pushed for the first time is private and not linked to the"
echo "upstream repo: link it once under Package settings -> Connect repository."
