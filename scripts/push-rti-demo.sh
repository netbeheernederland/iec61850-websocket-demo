#!/usr/bin/env bash
# Push the rti-demo images built by build-rti-demo.sh to the GitHub Container
# Registry by hand, as multi-platform images. See docs/docker-images-github.md,
# section 4.
#
# Usage: push-rti-demo.sh [--tag TAG] [--no-latest] [--platform ARCH[,ARCH]]
#                         [--dry-run] [fsp] [so] [bff] [hmi] [dr-panel] [dr-leds]
#        (no images: every one with an archive for each platform)
#
# Base images are rti-<image>; the plugins keep their own name (dr-panel).
# The images come from the archives build-rti-demo.sh wrote, one per
# platform in dist/rti-images-<arch>/. Per image the script
#   1. pushes each platform's image as <name>:<base>-<arch>
#      (e.g. rti-fsp:sha-1a2b3c4-arm64), where <base> is --tag, else latest;
#   2. combines them into one multi-platform image under latest and --tag,
#      so docker pull picks the machine's own platform;
#   3. puts the local image back as it was: loading the archives replaces it.
#
#   --tag TAG         extra registry tag next to latest, e.g. sha-1a2b3c4
#   --no-latest       push only the --tag tag, leave latest in the registry alone
#   --platform LIST   architectures, comma-separated (default: amd64,arm64).
#                     Every image needs an archive for each; leaving one out
#                     pushes images without it, which machines of that
#                     platform can't pull.
#   --dry-run         check the archives and the tags, push nothing
#
# Pushing needs a docker login with a token that has write:packages:
#   echo "${GHCR_TOKEN}" | docker login ghcr.io -u <github-user> --password-stdin
#   gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
#
# Environment:
#   RTI_REGISTRY   registry and namespace to push to
#                  (default: ghcr.io/netbeheernederland/iec61850-websocket)
#   RTI_DIST_DIR   directory with the rti-images-<arch>/ archive directories
#                  (default: dist)
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RTI_REGISTRY="${RTI_REGISTRY:-ghcr.io/netbeheernederland/iec61850-websocket}"
RTI_DIST_DIR="${RTI_DIST_DIR:-${REPO_ROOT}/dist}"
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

archive() { echo "${RTI_DIST_DIR}/rti-images-$1/$(image_name "$2").tar.gz"; }

# --- Arguments ----------------------------------------------------------
EXTRA_TAG=""
LATEST=1
PLATFORMS="amd64,arm64"
DRY_RUN=0
IMAGES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --tag)       need_value "$@"; EXTRA_TAG="$2"; shift ;;
    --platform)  need_value "$@"; PLATFORMS="$2"; shift ;;
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
# The per-platform tags hang off the pinned tag when there is one
ARCH_BASE="${EXTRA_TAG:-latest}"

IFS=, read -r -a ARCHES <<< "${PLATFORMS}"
for arch in "${ARCHES[@]}"; do
  case "${arch}" in
    amd64|arm64) ;;
    *) echo "Unsupported platform: ${arch} (use amd64, arm64)" >&2; exit 1 ;;
  esac
done

# Without arguments, take the images with an archive for every platform
if [ ${#IMAGES[@]} -eq 0 ]; then
  for image in "${ALL_IMAGES[@]}"; do
    complete=1
    for arch in "${ARCHES[@]}"; do
      [ -f "$(archive "${arch}" "${image}")" ] || complete=0
    done
    [ "${complete}" -eq 1 ] && IMAGES+=("${image}")
  done
  if [ ${#IMAGES[@]} -eq 0 ]; then
    echo "No image has archives for ${PLATFORMS} in ${RTI_DIST_DIR}/rti-images-<arch>/;" \
         "run build-rti-demo.sh first" >&2
    exit 1
  fi
fi

# --- Check every archive before pushing any --------------------------------
# The architecture is read from the image config inside the archive, so a
# wrongly placed archive never gets pushed under the other platform's tag.
archive_arch() {
  local tar="$1" tmp cfg arch=""
  tmp="$(mktemp -d)"
  if tar -xzf "${tar}" -C "${tmp}" manifest.json 2>/dev/null; then
    cfg="$(sed -n 's/.*"Config":"\([^"]*\)".*/\1/p' "${tmp}/manifest.json")"
    if [ -n "${cfg}" ] && tar -xzf "${tar}" -C "${tmp}" "${cfg}" 2>/dev/null; then
      arch="$(sed -n 's/.*"architecture":"\([^"]*\)".*/\1/p' "${tmp}/${cfg}")"
    fi
  fi
  rm -rf "${tmp}"
  echo "${arch}"
}

for image in "${IMAGES[@]}"; do
  for arch in "${ARCHES[@]}"; do
    tar="$(archive "${arch}" "${image}")"
    if [ ! -f "${tar}" ]; then
      echo "${tar} not found; run build-rti-demo.sh --platform linux/${arch} ${image} first" >&2
      exit 1
    fi
    found="$(archive_arch "${tar}")"
    if [ "${found}" != "${arch}" ]; then
      echo "${tar} is a ${found:-unknown} image, not ${arch}" >&2
      exit 1
    fi
  done
done

# A missing login only shows up as 'denied' halfway through the pushes
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
if [ "${DRY_RUN}" -eq 0 ] \
    && ! grep -qs "\"${REGISTRY_HOST}\"" "${DOCKER_CONFIG_FILE}"; then
  echo "Not logged in to ${REGISTRY_HOST}. Log in with a token that has write:packages:" >&2
  echo "  echo \"\${GHCR_TOKEN}\" | docker login ${REGISTRY_HOST} -u <github-user> --password-stdin" >&2
  exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  for image in "${IMAGES[@]}"; do
    name="$(image_name "${image}")"
    for arch in "${ARCHES[@]}"; do
      echo "(dry run) push $(archive "${arch}" "${image}") as ${RTI_REGISTRY}/${name}:${ARCH_BASE}-${arch}"
    done
    for tag in "${TAGS[@]}"; do
      echo "(dry run) combine them as ${RTI_REGISTRY}/${name}:${tag} (${PLATFORMS})"
    done
  done
  exit 0
fi

# --- Push -------------------------------------------------------------------
push_failed() {
  echo "Could not push $1." >&2
  echo "Check the token has write:packages and is SSO-authorised for the organisation." >&2
  exit 1
}

PUSHED=()
for image in "${IMAGES[@]}"; do
  name="$(image_name "${image}")"
  local_tag="${IMAGE_BASE}/${name}:latest"

  # docker load moves the local tag; remember the image to put back
  original="$(docker image inspect --format '{{.Id}}' "${local_tag}" 2>/dev/null || true)"

  sources=()
  for arch in "${ARCHES[@]}"; do
    remote="${RTI_REGISTRY}/${name}:${ARCH_BASE}-${arch}"
    echo "Loading $(archive "${arch}" "${image}")..."
    gunzip -c "$(archive "${arch}" "${image}")" | docker load -q >/dev/null
    docker tag "${local_tag}" "${remote}"
    echo "Pushing ${remote}..."
    docker push -q "${remote}" >/dev/null || push_failed "${remote}"
    docker rmi "${remote}" >/dev/null
    sources+=("${remote}")
    PUSHED+=("${remote}")
  done

  if [ -n "${original}" ]; then
    docker tag "${original}" "${local_tag}"
  fi

  tag_args=()
  for tag in "${TAGS[@]}"; do
    tag_args+=(-t "${RTI_REGISTRY}/${name}:${tag}")
    PUSHED+=("${RTI_REGISTRY}/${name}:${tag} (${PLATFORMS})")
  done
  echo "Combining them as ${TAGS[*]}..."
  if ! out="$(docker buildx imagetools create "${tag_args[@]}" "${sources[@]}" 2>&1)"; then
    echo "${out}" >&2
    push_failed "${RTI_REGISTRY}/${name}:${TAGS[*]}"
  fi
done

echo
echo "Pushed:"
printf '  %s\n' "${PUSHED[@]}"
echo
echo "Keep the -<arch> tags: the multi-platform tags point at them. A package"
echo "pushed for the first time is private and not linked to the upstream repo:"
echo "change both once under Package settings (Connect repository)."
