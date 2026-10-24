#!/bin/bash
# Assembles the source tree of a nightly from the snapshot orig and the packaging's debian/, as SOURCE_TAR for debuild.sh.
# Drops the patches the snapshot already has, and prepends a changelog entry of CHANGELOG_VERSION.
set -euxo pipefail
: "${SOURCE:?}" "${ORIG_NAME:?}" "${CHANGELOG_VERSION:?}" "${BRANCH:?}" "${REVISION:?}" "${SOURCE_TAR:?}"

work="${RUNNER_TEMP}/nightly"
tree="${work}/${SOURCE}"
check="${work}/check"
mkdir -p "$tree" "$check"
tar -C "$tree" --strip-components=1 -xzf "${GITHUB_WORKSPACE}/orig/${ORIG_NAME}"
tar -C "$check" --strip-components=1 -xzf "${GITHUB_WORKSPACE}/orig/${ORIG_NAME}"
cp -a "${GITHUB_WORKSPACE}/src/debian" "${tree}/"

# Patches are tried in order on a scratch copy, as each may depend on the ones before it.
series="${tree}/debian/patches/series"
if [[ -f "$series" ]]; then
  kept=()
  while read -r patch _; do
    [[ -z "$patch" || "$patch" == \#* ]] && continue
    file="${tree}/debian/patches/${patch}"
    if patch -d "$check" -p1 -s -f --dry-run < "$file" > /dev/null; then
      patch -d "$check" -p1 -s -f < "$file"
      kept+=("$patch")
    elif patch -d "$check" -p1 -s -f -R --dry-run < "$file" > /dev/null; then
      echo "::notice title=${SOURCE} ${patch}::already in ${BRANCH}; dropped"
    else
      echo "::error title=${SOURCE} ${patch}::does not apply to ${BRANCH} at ${REVISION}"
      exit 1
    fi
  done < "$series"
  : > "$series"
  if (( ${#kept[@]} )); then
    printf '%s\n' "${kept[@]}" > "$series"
  fi
fi

changelog="${tree}/debian/changelog"
maintainer="$(sed -n -e 's/^ -- \(.*>\)  .*$/\1/p' "$changelog" | head -n1)"
{
  printf '%s (%s) unstable; urgency=medium\n\n' "$SOURCE" "$CHANGELOG_VERSION"
  printf '  * Snapshot of %s at %s.\n\n' "$BRANCH" "$REVISION"
  printf ' -- %s  %s\n\n' "$maintainer" "$(LC_ALL=C date -R)"
  cat "$changelog"
} > "${work}/changelog"
mv "${work}/changelog" "$changelog"
head -n 6 "$changelog"

tar -C "$work" -cf "$SOURCE_TAR" "$SOURCE"
