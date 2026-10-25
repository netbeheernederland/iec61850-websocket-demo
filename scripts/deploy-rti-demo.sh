#!/usr/bin/env bash
# Copy the rti-demo image archives built by build-rti-demo.sh, plus a role's
# files, to one or more running Pis. The files per host are put together by
# stage-rti-role.sh; setup/pi-user-data.sh --role writes the same files into
# a Pi image instead, so the Pi starts its role on first boot.
#
# Usage: deploy-rti-demo.sh [--start] --role ROLE [fsp options] [user@]host ...
#                                    [--role ROLE [fsp options] [user@]host ...]
#
#   --role ROLE     so or fsp: the role of the hosts after it
#   [user@]host     a Pi, by hostname or IP address; without user@ the login
#                   user is TARGET_USER
#   --start         also run load-and-start.sh on each host after copying
#
# fsp options, for the fsp hosts after them (until given again):
#   --cp CP         control point (default: cp1)
#   --port PORT     ACSI server port (default: 5001)
#   --model FILE    model file to copy to the Pi and load (default: none,
#                   fsp's built-in model), e.g. modules/fsp02/models/model_2.py
#
# Examples:
#   deploy-rti-demo.sh --role so 192.168.100.97
#   deploy-rti-demo.sh --start --role fsp --model modules/fsp01/models/model_1.py pi@rti-pi5.local
#   deploy-rti-demo.sh --role so 192.168.100.97 \
#     --role fsp --cp cp1 --model modules/fsp01/models/model_1.py 192.168.100.98 \
#                --cp cp2 --port 5005 --model modules/fsp02/models/model_2.py 192.168.100.99
#
# Environment:
#   TARGET_USER    login user for hosts without user@ (default: rti)
#   RTI_IMAGE_DIR  where build-rti-demo.sh wrote the archives
#                  (default: dist/rti-images-arm64, the Pis' architecture)
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images-arm64}"

# Login user on the Pis: rti, as created by setup/pi-user-data.sh (VM_USER in
# setup/roles.env). Override for a Pi set up otherwise, e.g. TARGET_USER=pi.
TARGET_USER="${TARGET_USER:-rti}"
TARGET_DIR="rti"                               # relative to the user's home

# Puts the role's files for one host in a directory
STAGE_SCRIPT="${SCRIPT_DIR}/stage-rti-role.sh"

usage() {
  # The header comment, from Usage: to the end
  sed -n '/^# Usage:/,/^set -e/{/^set -e/d;s/^# \{0,1\}//p;}' "$0" >&2
  exit "${1:-1}"
}

# --- Arguments ----------------------------------------------------------
# Each host is recorded with the role and fsp options in effect where it
# appears on the command line.
START=false
ROLE=""
FSP_CP="cp1"
FSP_PORT="5001"
FSP_MODEL=""
TARGETS=()
declare -A T_ROLE=() T_CP=() T_PORT=() T_MODEL=()

need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    echo "$1 needs a value" >&2
    usage
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --start) START=true ;;
    --role)
      need_value "$@"
      case "$2" in
        so|fsp) ;;
        *) echo "Unknown role: $2 (known: so fsp)" >&2; usage ;;
      esac
      ROLE="$2"; shift ;;
    --cp) need_value "$@"; FSP_CP="$2"; shift ;;
    --port)
      need_value "$@"
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "--port needs a number: $2" >&2
        usage
      fi
      FSP_PORT="$2"; shift ;;
    --model)
      need_value "$@"
      if [ ! -f "$2" ]; then
        echo "Model file not found: $2" >&2
        exit 1
      fi
      FSP_MODEL="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      if [ -z "${ROLE}" ]; then
        echo "No --role given before host $1" >&2
        usage
      fi
      host="$1"
      case "${host}" in
        *@*) ;;
        *) host="${TARGET_USER}@${host}" ;;
      esac
      if [ -z "${host#*@}" ] || [ -z "${host%%@*}" ]; then
        echo "Not a [user@]host: $1" >&2
        usage
      fi
      if [ -n "${T_ROLE[${host}]+x}" ]; then
        echo "Host given twice: ${host}" >&2
        exit 1
      fi
      TARGETS+=("${host}")
      T_ROLE[${host}]="${ROLE}"
      T_CP[${host}]="${FSP_CP}"
      T_PORT[${host}]="${FSP_PORT}"
      T_MODEL[${host}]="${FSP_MODEL}"
      ;;
  esac
  shift
done

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "No hosts given" >&2
  usage
fi

# --- Stage every host before touching any machine ------------------------
# stage-rti-role.sh stops on a missing archive or compose file.
declare -A cp_hosts=()
for t in "${TARGETS[@]}"; do
  [ "${T_ROLE[${t}]}" = "fsp" ] && cp_hosts[${T_CP[${t}]}]+=" ${t}"
done
for cp in "${!cp_hosts[@]}"; do
  read -ra hosts <<<"${cp_hosts[${cp}]}"
  if [ ${#hosts[@]} -gt 1 ]; then
    echo "Warning: fsp hosts share control point ${cp}:${cp_hosts[${cp}]} (give each its own --cp)" >&2
  fi
done

STAGE_DIR="$(mktemp -d -t rti-deploy-XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

for t in "${TARGETS[@]}"; do
  args=(--role "${T_ROLE[${t}]}")
  if [ "${T_ROLE[${t}]}" = "fsp" ]; then
    args+=(--cp "${T_CP[${t}]}" --port "${T_PORT[${t}]}")
    [ -n "${T_MODEL[${t}]}" ] && args+=(--model "${T_MODEL[${t}]}")
  fi
  "${STAGE_SCRIPT}" "${args[@]}" "${STAGE_DIR}/${t}"
done

# --- Deploy ---------------------------------------------------------------
deploy_host() {
  local t="$1"

  echo "=== ${t}:${TARGET_DIR}, role ${T_ROLE[${t}]}"
  # tar keeps .env and models/ and creates the target directory
  tar -C "${STAGE_DIR}/${t}" -cf - . \
    | ssh "${t}" "mkdir -p ${TARGET_DIR} && tar -C ${TARGET_DIR} -xf -"

  if ${START}; then
    echo "Loading images and starting compose on ${t}..."
    ssh "${t}" "cd ${TARGET_DIR} && ./load-and-start.sh"
  fi
}

for t in "${TARGETS[@]}"; do
  deploy_host "${t}"
done

if ! ${START}; then
  echo "On each host, run: cd ${TARGET_DIR} && ./load-and-start.sh"
  echo "(or re-run with --start to do this over ssh)"
fi

echo "Done."
