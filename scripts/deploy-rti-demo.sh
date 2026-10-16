#!/usr/bin/env bash
# Copy the rti-demo image archives built by build-rti-demo.sh, plus a role's
# files, to one or more Pis.
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
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images}"

# Login user on the Pis: rti, as created by setup/pi-user-data.sh (VM_USER in
# setup/roles.env). Override for a Pi set up otherwise, e.g. TARGET_USER=pi.
TARGET_USER="${TARGET_USER:-rti}"
TARGET_DIR="rti"                               # relative to the user's home

# Script run on the target machine to load the image archives and start compose
LOAD_AND_START_SCRIPT="${SCRIPT_DIR}/load-and-start.sh"

# Images each role runs; its compose file is modules/<role>/docker-compose.yml
declare -A ROLE_IMAGES=(
  [so]="rti-so rti-io"
  [fsp]="rti-fsp rti-io"
)

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
      if [ -z "${ROLE_IMAGES[$2]+x}" ]; then
        echo "Unknown role: $2 (known: ${!ROLE_IMAGES[*]})" >&2
        usage
      fi
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

# --- Check everything is in place before touching any machine -------------
missing=()
declare -A cp_hosts=()
for t in "${TARGETS[@]}"; do
  role="${T_ROLE[${t}]}"
  for image in ${ROLE_IMAGES[${role}]}; do
    [ -f "${RTI_IMAGE_DIR}/${image}.tar.gz" ] || missing+=("${RTI_IMAGE_DIR}/${image}.tar.gz")
  done
  [ -f "${REPO_ROOT}/modules/${role}/docker-compose.yml" ] \
    || missing+=("${REPO_ROOT}/modules/${role}/docker-compose.yml")
  [ "${role}" = "fsp" ] && cp_hosts[${T_CP[${t}]}]+=" ${t}"
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing files (run scripts/build-rti-demo.sh first for the images):" >&2
  printf '  %s\n' "${missing[@]}" | sort -u >&2
  exit 1
fi
for cp in "${!cp_hosts[@]}"; do
  read -ra hosts <<<"${cp_hosts[${cp}]}"
  if [ ${#hosts[@]} -gt 1 ]; then
    echo "Warning: fsp hosts share control point ${cp}:${cp_hosts[${cp}]} (give each its own --cp)" >&2
  fi
done

# --- Deploy ---------------------------------------------------------------
STAGE_DIR="$(mktemp -d -t rti-deploy-XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

# The host's .env, read by docker compose next to docker-compose.yml
write_env() {
  local t="$1" file="$2"
  {
    echo "# Written by scripts/deploy-rti-demo.sh for ${t} (role ${T_ROLE[${t}]})"
    if [ "${T_ROLE[${t}]}" = "fsp" ]; then
      echo "FSP_CP=${T_CP[${t}]}"
      echo "FSP_PORT=${T_PORT[${t}]}"
      if [ -n "${T_MODEL[${t}]}" ]; then
        echo "FSP_MODELPATH=/models/$(basename "${T_MODEL[${t}]}")"
      fi
    fi
  } > "${file}"
}

deploy_host() {
  local t="$1" role env_file
  local files=()
  role="${T_ROLE[${t}]}"
  env_file="${STAGE_DIR}/${t}.env"
  write_env "${t}" "${env_file}"

  for image in ${ROLE_IMAGES[${role}]}; do
    files+=("${RTI_IMAGE_DIR}/${image}.tar.gz")
  done
  files+=("${REPO_ROOT}/modules/${role}/docker-compose.yml" "${LOAD_AND_START_SCRIPT}")

  echo "=== ${t}:${TARGET_DIR}, role ${role}"
  # scp needs the target directory to exist when copying several files;
  # models/ is created for every host, so compose never makes it as root
  ssh "${t}" mkdir -p "${TARGET_DIR}/models"
  scp "${files[@]}" "${t}:${TARGET_DIR}"
  scp "${env_file}" "${t}:${TARGET_DIR}/.env"
  if [ "${role}" = "fsp" ] && [ -n "${T_MODEL[${t}]}" ]; then
    scp "${T_MODEL[${t}]}" "${t}:${TARGET_DIR}/models/"
  fi

  if ${START}; then
    echo "Loading images and starting compose on ${t}..."
    ssh "${t}" "cd ${TARGET_DIR} && chmod +x load-and-start.sh && ./load-and-start.sh"
  fi
}

for t in "${TARGETS[@]}"; do
  deploy_host "${t}"
done

if ! ${START}; then
  echo "On each host, run: cd ${TARGET_DIR} && chmod +x load-and-start.sh && ./load-and-start.sh"
  echo "(or re-run with --start to do this over ssh)"
fi

echo "Done."
