#!/usr/bin/env bash
# Put the files one Pi needs for its role in a directory: the role's image
# archives (its base image and the plugins it runs), its docker-compose.yml,
# an .env with the plugins and the fsp settings, the fsp model and
# load-and-start.sh. deploy-rti-demo.sh copies the directory to a
# running Pi; setup/pi-user-data.sh writes it to a Pi image's boot partition,
# where cloud-init picks it up on first boot.
#
# Usage: stage-rti-role.sh --role ROLE [--plugins LIST] [--cp CP] [--port PORT]
#                          [--model FILE] DIR
#
#   --role ROLE     so or fsp
#   --plugins LIST  plugins to run, comma-separated (dr-panel, dr-leds), or
#                   none (default: so dr-panel,dr-leds; fsp dr-leds)
#   --cp CP         fsp: control point (default: cp1)
#   --port PORT     fsp: ACSI server port (default: 5001)
#   --model FILE    fsp: model file to load (default: none, fsp's built-in model)
#   DIR             directory to fill; created if needed, must be empty
#
# Environment:
#   RTI_IMAGE_DIR  where build-rti-demo.sh wrote the archives
#                  (default: dist/rti-images-arm64, the Pis' architecture)
set -euo pipefail

# --- Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RTI_IMAGE_DIR="${RTI_IMAGE_DIR:-${REPO_ROOT}/dist/rti-images-arm64}"

# Script run on the target machine to load the image archives and start compose
LOAD_AND_START_SCRIPT="${SCRIPT_DIR}/load-and-start.sh"

# Each role's base image and the plugins it runs without --plugins; its
# compose file is modules/<role>/docker-compose.yml
declare -A ROLE_IMAGE=(
  [so]="rti-so"
  [fsp]="rti-fsp"
)
declare -A ROLE_PLUGINS=(
  [so]="dr-panel,dr-leds"
  [fsp]="dr-leds"
)

# The plugins, by image name: their name and URL in the base image's PLUGINS
# (upstream decision 0029). Each is a compose profile of the same name.
declare -A PLUGIN_NAME=(
  [dr-panel]="dr_panel"
  [dr-leds]="dr_leds"
)
declare -A PLUGIN_URL=(
  [dr-panel]="http://dr-panel:9000/plugin"
  [dr-leds]="http://dr-leds:8099/plugin"
)

usage() {
  # The header comment, from Usage: to the end
  sed -n '/^# Usage:/,/^set -e/{/^set -e/d;s/^# \{0,1\}//p;}' "$0" >&2
  exit "${1:-1}"
}

# --- Arguments ----------------------------------------------------------
ROLE=""
PLUGINS_OPT=""
FSP_CP="cp1"
FSP_PORT="5001"
FSP_MODEL=""
DIR=""

need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    echo "$1 needs a value" >&2
    usage
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --role)
      need_value "$@"
      if [ -z "${ROLE_IMAGE[$2]+x}" ]; then
        echo "Unknown role: $2 (known: ${!ROLE_IMAGE[*]})" >&2
        usage
      fi
      ROLE="$2"; shift ;;
    --plugins) need_value "$@"; PLUGINS_OPT="$2"; shift ;;
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
      FSP_MODEL="$2"; shift ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      if [ -n "${DIR}" ]; then
        echo "More than one directory given: ${DIR} $1" >&2
        usage
      fi
      DIR="$1" ;;
  esac
  shift
done

if [ -z "${ROLE}" ] || [ -z "${DIR}" ]; then
  usage
fi

# The plugins, in the order given, each once
PLUGINS=()
if [ "${PLUGINS_OPT:-${ROLE_PLUGINS[${ROLE}]}}" != none ]; then
  IFS=, read -ra list <<<"${PLUGINS_OPT:-${ROLE_PLUGINS[${ROLE}]}}"
  for plugin in "${list[@]}"; do
    if [ -z "${PLUGIN_NAME[${plugin}]+x}" ]; then
      echo "Unknown plugin: ${plugin} (known: ${!PLUGIN_NAME[*]}, or none)" >&2
      usage
    fi
    [[ " ${PLUGINS[*]} " == *" ${plugin} "* ]] || PLUGINS+=("${plugin}")
  done
fi
IMAGES=("${ROLE_IMAGE[${ROLE}]}" "${PLUGINS[@]}")

# --- Check everything is in place before writing anything -----------------
missing=()
for image in "${IMAGES[@]}"; do
  [ -f "${RTI_IMAGE_DIR}/${image}.tar.gz" ] || missing+=("${RTI_IMAGE_DIR}/${image}.tar.gz")
done
[ -f "${REPO_ROOT}/modules/${ROLE}/docker-compose.yml" ] \
  || missing+=("${REPO_ROOT}/modules/${ROLE}/docker-compose.yml")
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing files (run scripts/build-rti-demo.sh first for the images; pull-rti-demo.sh has no plugins):" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

mkdir -p "${DIR}"
if [ -n "$(ls -A "${DIR}")" ]; then
  echo "Not empty: ${DIR}" >&2
  exit 1
fi

# --- Stage ----------------------------------------------------------------
for image in "${IMAGES[@]}"; do
  cp "${RTI_IMAGE_DIR}/${image}.tar.gz" "${DIR}/"
done
cp "${REPO_ROOT}/modules/${ROLE}/docker-compose.yml" "${LOAD_AND_START_SCRIPT}" "${DIR}/"
chmod +x "${DIR}/load-and-start.sh"

# models/ exists for every role, so compose never creates it as root
mkdir -p "${DIR}/models"
if [ "${ROLE}" = "fsp" ] && [ -n "${FSP_MODEL}" ]; then
  cp "${FSP_MODEL}" "${DIR}/models/"
fi

# The base image's PLUGINS: where it reaches itself and each plugin
if [ "${ROLE}" = "fsp" ]; then
  host_url="http://rti-fsp:${FSP_PORT}"
else
  host_url="http://rti-so:5000"
fi
entries=""
for plugin in "${PLUGINS[@]}"; do
  entries+="${entries:+, }{\"name\": \"${PLUGIN_NAME[${plugin}]}\", \"url\": \"${PLUGIN_URL[${plugin}]}\"}"
done
plugins_json="{\"host_url\": \"${host_url}\", \"plugins\": [${entries}]}"

# The host's .env, read by docker compose next to docker-compose.yml.
# COMPOSE_PROFILES starts the plugins' services; single quotes keep the JSON
# as it is.
{
  echo "# Written by scripts/stage-rti-role.sh (role ${ROLE})"
  echo "COMPOSE_PROFILES=$(IFS=,; echo "${PLUGINS[*]}")"
  echo "RTI_PLUGINS='${plugins_json}'"
  if [ "${ROLE}" = "fsp" ]; then
    echo "FSP_CP=${FSP_CP}"
    echo "FSP_PORT=${FSP_PORT}"
    if [ -n "${FSP_MODEL}" ]; then
      echo "FSP_MODELPATH=/models/$(basename "${FSP_MODEL}")"
    fi
  fi
} > "${DIR}/.env"
