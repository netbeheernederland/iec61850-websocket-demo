#!/usr/bin/env bash
# Copy the rti-demo image archives built by build-rti-demo.sh, plus each
# machine's role files, to one or more Pis.
#
# Usage: deploy-rti-demo.sh [--start] [machine ...]   (no machines: all)
#        deploy-rti-demo.sh --list
#
#   --start  also run load-and-start.sh on each machine after copying
#   --list   show the known machines and exit
#
# Environment:
#   TARGET_USER    login user on the Pis (default: rti)
#   SO_HOST        address of the so machine
#   FSP01_HOST     address of the fsp01 machine
#   RTI_IMAGE_DIR  where build-rti-demo.sh wrote the archives
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images}"

# Login user on the Pis: rti, as created by setup/pi-user-data.sh (VM_USER in
# setup/roles.env). Override for a Pi set up otherwise, e.g. TARGET_USER=pi.
TARGET_USER="${TARGET_USER:-rti}"
TARGET_DIR="rti"                               # relative to TARGET_USER's home

# Script run on the target machine to load the image archives and start compose
LOAD_AND_START_SCRIPT="${SCRIPT_DIR}/load-and-start.sh"

# The machines. Each one receives the image archives listed here, plus
# modules/<machine>/docker-compose.yml and, if present, modules/<machine>/models/.
MACHINES=(so fsp01)
declare -A MACHINE_HOST=(
  [so]="${SO_HOST:-192.168.100.97}"
  [fsp01]="${FSP01_HOST:-192.168.100.98}"
)
declare -A MACHINE_IMAGES=(
  [so]="rti-so rti-io"
  [fsp01]="rti-fsp rti-io"
)

usage() {
  echo "Usage: $(basename "$0") [--start] [machine ...]   (no machines: all)" >&2
  echo "       $(basename "$0") --list" >&2
  echo "Machines: ${MACHINES[*]}" >&2
  exit "${1:-1}"
}

list_machines() {
  for m in "${MACHINES[@]}"; do
    printf '%-8s %s@%s  images: %s\n' \
      "${m}" "${TARGET_USER}" "${MACHINE_HOST[${m}]}" "${MACHINE_IMAGES[${m}]}"
  done
}

# --- Arguments ----------------------------------------------------------
START=false
SELECTED=()
for arg in "$@"; do
  case "${arg}" in
    -h|--help) usage 0 ;;
    --list) list_machines; exit 0 ;;
    --start) START=true ;;
    -*) echo "Unknown option: ${arg}" >&2; usage ;;
    *)
      if [ -z "${MACHINE_HOST[${arg}]+x}" ]; then
        echo "Unknown machine: ${arg}" >&2
        usage
      fi
      SELECTED+=("${arg}")
      ;;
  esac
done
[ ${#SELECTED[@]} -eq 0 ] && SELECTED=("${MACHINES[@]}")

# --- Check everything is in place before touching any machine -------------
missing=()
for m in "${SELECTED[@]}"; do
  for image in ${MACHINE_IMAGES[${m}]}; do
    [ -f "${RTI_IMAGE_DIR}/${image}.tar.gz" ] || missing+=("${RTI_IMAGE_DIR}/${image}.tar.gz")
  done
  [ -f "${REPO_ROOT}/modules/${m}/docker-compose.yml" ] \
    || missing+=("${REPO_ROOT}/modules/${m}/docker-compose.yml")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing files (run scripts/build-rti-demo.sh first for the images):" >&2
  printf '  %s\n' "${missing[@]}" | sort -u >&2
  exit 1
fi

# --- Deploy ---------------------------------------------------------------
deploy_machine() {
  local m="$1"
  local target="${TARGET_USER}@${MACHINE_HOST[${m}]}"
  local files=()

  for image in ${MACHINE_IMAGES[${m}]}; do
    files+=("${RTI_IMAGE_DIR}/${image}.tar.gz")
  done
  files+=("${REPO_ROOT}/modules/${m}/docker-compose.yml" "${LOAD_AND_START_SCRIPT}")
  [ -d "${REPO_ROOT}/modules/${m}/models" ] && files+=("${REPO_ROOT}/modules/${m}/models")

  echo "=== ${m} (${target}:${TARGET_DIR})"
  # scp needs the target directory to exist when copying several files
  ssh "${target}" mkdir -p "${TARGET_DIR}"
  scp -r "${files[@]}" "${target}:${TARGET_DIR}"

  if ${START}; then
    echo "Loading images and starting compose on ${m}..."
    ssh "${target}" "cd ${TARGET_DIR} && chmod +x load-and-start.sh && ./load-and-start.sh"
  fi
}

for m in "${SELECTED[@]}"; do
  deploy_machine "${m}"
done

if ! ${START}; then
  echo "On each target machine, run: cd ${TARGET_DIR} && chmod +x load-and-start.sh && ./load-and-start.sh"
  echo "(or re-run with --start to do this over ssh)"
fi

echo "Done."
