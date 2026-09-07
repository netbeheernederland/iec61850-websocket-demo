#!/usr/bin/env bash
# Convenience wrapper: render -> make-disks -> launch.
# Prerequisites (run once, in order):
#   ./download-images.sh    # Ubuntu cloud image
#   ./build-base.sh         # golden image with docker/avahi/dhcpd baked in
#   ./build-tarballs.sh     # docker save of the rti-demo_* images
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"${here}/render.sh"
"${here}/make-disks.sh"
"${here}/launch.sh"
