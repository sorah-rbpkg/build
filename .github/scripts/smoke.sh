#!/bin/bash
# Installs the built packages on a stock image of the distro and runs .github/scripts/smoke/<SMOKE>.sh there.
set -euxo pipefail
: "${IMAGE:?}" "${SMOKE:?}" "${SOURCE:?}" "${DISTRO:?}" "${ARCH:?}"

docker run --rm \
  --volume "${GITHUB_WORKSPACE}/out:/debs:ro" \
  --volume "${GITHUB_WORKSPACE}/keys:/keys:ro" \
  --volume "${GITHUB_WORKSPACE}/.github/scripts/smoke:/smoke:ro" \
  -e SOURCE -e DISTRO -e ARCH \
  "$IMAGE" bash "/smoke/${SMOKE}.sh"
