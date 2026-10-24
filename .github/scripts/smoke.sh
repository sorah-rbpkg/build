#!/bin/bash
# Installs the built packages on a stock image of the distro and runs .github/scripts/smoke/<SMOKE>.sh there.
set -euxo pipefail
: "${IMAGE:?}" "${SMOKE:?}" "${SOURCE:?}" "${DISTRO:?}" "${ARCH:?}"
# The apt suite the package goes to; nightly packages have none of their own.
export SUITE="${SUITE:-$DISTRO}"

docker run --rm \
  --volume "${GITHUB_WORKSPACE}/out:/debs:ro" \
  --volume "${GITHUB_WORKSPACE}/keys:/keys:ro" \
  --volume "${GITHUB_WORKSPACE}/.github/scripts/smoke:/smoke:ro" \
  -e SOURCE -e DISTRO -e SUITE -e ARCH \
  "$IMAGE" bash "/smoke/${SMOKE}.sh"
