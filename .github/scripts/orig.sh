#!/bin/bash
# Generates the orig tarball from the upstream tag's commit, whose signature bin/plan checked.
set -euxo pipefail
: "${REPOSITORY:?}" "${SOURCE:?}" "${UPSTREAM_VERSION:?}" "${UPSTREAM_COMMIT:?}" "${ORIG_NAME:?}"

work="${RUNNER_TEMP}/orig"
git init -q "$work"
git -C "$work" fetch --no-tags --depth=1 "https://github.com/${REPOSITORY}.git" "$UPSTREAM_COMMIT"
mkdir -p "${GITHUB_WORKSPACE}/out"
orig="${GITHUB_WORKSPACE}/out/${ORIG_NAME}"
git -C "$work" archive --format=tar --prefix "${SOURCE}-${UPSTREAM_VERSION}/" "$UPSTREAM_COMMIT" | gzip -n > "$orig"
sha256sum "$orig"

# The apt repository's pool rejects a second orig of the same name with different bytes.
case "$SOURCE" in
  lib*) pool_dir="${SOURCE:0:4}/${SOURCE}" ;;
  *) pool_dir="${SOURCE:0:1}/${SOURCE}" ;;
esac
pool_url="https://cache.ruby-lang.org/lab/sorah/deb/pool/main/${pool_dir}/${ORIG_NAME}"
pooled="${RUNNER_TEMP}/pooled.orig.tar.gz"
status=$(curl -sS -o "$pooled" -w '%{http_code}' "$pool_url")
case "$status" in
  200)
    sha256sum "$pooled"
    if ! cmp -s "$orig" "$pooled"; then
      echo "::error::${ORIG_NAME} differs from the one in the apt repository at ${pool_url}"
      exit 1
    fi
    ;;
  # The bucket answers 403 for a missing object.
  403|404) echo "::notice::${ORIG_NAME} is not in the apt repository yet" ;;
  *)
    echo "::error::GET ${pool_url} returned ${status}"
    exit 1
    ;;
esac
