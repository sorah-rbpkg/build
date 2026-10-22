#!/bin/bash
# Generates the orig tarball from the upstream tag's commit, whose signature bin/plan checked.
set -euxo pipefail
: "${REPOSITORY:?}" "${SOURCE:?}" "${UPSTREAM_VERSION:?}" "${UPSTREAM_COMMIT:?}" "${ORIG_NAME:?}"

work="${RUNNER_TEMP}/orig"
git init -q "$work"
git -C "$work" fetch --no-tags --depth=1 "https://github.com/${REPOSITORY}.git" "$UPSTREAM_COMMIT"
mkdir -p "${GITHUB_WORKSPACE}/out"
git -C "$work" archive --format=tar --prefix "${SOURCE}-${UPSTREAM_VERSION}/" "$UPSTREAM_COMMIT" | gzip -n > "${GITHUB_WORKSPACE}/out/${ORIG_NAME}"
sha256sum "${GITHUB_WORKSPACE}/out/${ORIG_NAME}"
