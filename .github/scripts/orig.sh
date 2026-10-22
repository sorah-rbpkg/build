#!/bin/bash
# Generates the orig tarball from the upstream tag.
set -euxo pipefail
: "${REPOSITORY:?}" "${SOURCE:?}" "${UPSTREAM_VERSION:?}" "${UPSTREAM_TAG:?}" "${ORIG_NAME:?}"

work="${RUNNER_TEMP}/orig"
git init -q "$work"
git -C "$work" fetch --no-tags --depth=1 "https://github.com/${REPOSITORY}.git" "+refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
mkdir -p "${GITHUB_WORKSPACE}/out"
git -C "$work" archive --format=tar --prefix "${SOURCE}-${UPSTREAM_VERSION}/" "$UPSTREAM_TAG" | gzip -n > "${GITHUB_WORKSPACE}/out/${ORIG_NAME}"
sha256sum "${GITHUB_WORKSPACE}/out/${ORIG_NAME}"
