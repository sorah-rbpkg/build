#!/bin/bash
# Installs the built packages on a stock image of the distro and exercises the interpreter and bundled tools.
set -euxo pipefail
: "${IMAGE:?}" "${SOURCE:?}" "${DISTRO:?}" "${ARCH:?}"

docker run --rm \
  --volume "${GITHUB_WORKSPACE}/out:/debs:ro" \
  --volume "${GITHUB_WORKSPACE}/keys:/keys:ro" \
  --volume "${GITHUB_WORKSPACE}/.github/scripts/smoke-container.sh:/smoke-container.sh:ro" \
  -e DISTRO -e ARCH -e "RUBY_VERSION=${SOURCE#ruby}" \
  "$IMAGE" bash /smoke-container.sh
