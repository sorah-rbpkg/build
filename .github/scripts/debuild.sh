#!/bin/bash
# Builds the staged source tree in the image from DOCKERFILE, which bin/plan picked.
set -euxo pipefail
: "${SOURCE:?}" "${DISTRO:?}" "${BUILD:?}" "${DOCKERFILE:?}" "${JOB_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
# ORIG_NAME is empty for a native package.
ORIG_NAME="${ORIG_NAME:-}"

echo "To kill this build, add this line to kills.txt on main: ${JOB_ID} ${GITHUB_RUN_ATTEMPT}"

src="${GITHUB_WORKSPACE}/src"
out="${GITHUB_WORKSPACE}/out"
work="${RUNNER_TEMP}/debuild"
mkdir -p "$out" "$work"

# A nightly brings its own tree from nightly-prepare.sh.
if [[ -n "${SOURCE_TAR:-}" ]]; then
  cp "$SOURCE_TAR" "${work}/source.tar"
else
  git -C "$src" archive --format=tar --prefix "${SOURCE}/" HEAD > "${work}/source.tar"
fi
if [[ -n "$ORIG_NAME" ]]; then
  cp "${GITHUB_WORKSPACE}/orig/${ORIG_NAME}" "${work}/"
fi

docker buildx build -f "${GITHUB_WORKSPACE}/${DOCKERFILE}" -t debuild --load "${src}/debian"

log="${work}/build.log"
touch "$log"
"${GITHUB_WORKSPACE}/.github/scripts/watchdog.sh" "$log" &
watchdog=$!
trap 'kill "$watchdog" 2>/dev/null || true' EXIT

# --privileged as sorah-debuild runs it, which the test suite has been passing under.
# TERM=xterm matches its --tty, as debuild otherwise sets TERM=dumb.
docker run --rm --privileged --name debuild \
  --volume "${work}:/work:ro" \
  --volume "${out}:/output" \
  --volume "${GITHUB_WORKSPACE}/.github/scripts/debuild-container.sh:/debuild-container.sh:ro" \
  -e SOURCE -e DISTRO -e ORIG_NAME -e BUILD \
  -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
  -e TERM=xterm \
  debuild bash /debuild-container.sh 2>&1 | tee "$log"

ls -l "$out"
