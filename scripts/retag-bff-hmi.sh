#!/usr/bin/env bash
# Retags the already-built rti-bff and rti-hmi images under the
# netbeheer-nederland/iec61850-websocket base name.
set -euo pipefail

IMAGE_BASE="netbeheer-nederland/iec61850-websocket"

IMAGE_BFF="rti-demo-rti-bff"
IMAGE_HMI="rti-demo-rti-hmi"

IMAGE_BFF_TAGGED="${IMAGE_BASE}/rti-bff"
IMAGE_HMI_TAGGED="${IMAGE_BASE}/rti-hmi"

echo "Tagging ${IMAGE_BFF} as ${IMAGE_BFF_TAGGED}..."
docker tag "${IMAGE_BFF}" "${IMAGE_BFF_TAGGED}"

echo "Tagging ${IMAGE_HMI} as ${IMAGE_HMI_TAGGED}..."
docker tag "${IMAGE_HMI}" "${IMAGE_HMI_TAGGED}"

echo "Done."
