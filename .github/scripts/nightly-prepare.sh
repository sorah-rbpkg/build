#!/bin/bash
# Assembles the source tree of a nightly from the snapshot orig and the packaging's debian/, as SOURCE_TAR for debuild.sh.
# Drops the patches the snapshot already has or DROP_PATCHES names, prepends a changelog entry of CHANGELOG_VERSION, and lets the symbols differ.
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
# dpkg-source allows no fuzz, so a patch that needs some is rewritten from the scratch copy's diff.
series="${tree}/debian/patches/series"
if [[ -f "$series" ]]; then
  scratch_git() { git -C "$check" -c user.name=nightly -c user.email=nightly@localhost "$@"; }
  scratch_git init -q
  scratch_git add -A -f
  scratch_git commit -q -m orig
  for patch in ${DROP_PATCHES:-}; do
    awk -v p="$patch" '$1 == p { found = 1 } END { exit !found }' "$series" ||
      echo "::warning title=${SOURCE} ${patch}::in nightly_drop but not in debian/patches/series"
  done
  kept=()
  while read -r patch _; do
    [[ -z "$patch" || "$patch" == \#* ]] && continue
    if [[ " ${DROP_PATCHES:-} " == *" ${patch} "* ]]; then
      echo "::notice title=${SOURCE} ${patch}::in nightly_drop; dropped"
      continue
    fi
    file="${tree}/debian/patches/${patch}"
    if patch -d "$check" -p1 -s -f -F 0 --dry-run < "$file" > /dev/null; then
      patch -d "$check" -p1 -s -f -F 0 --no-backup-if-mismatch < "$file"
      scratch_git add -A -f
      scratch_git commit -q -m "$patch"
      kept+=("$patch")
    elif patch -d "$check" -p1 -s -f --dry-run < "$file" > /dev/null; then
      patch -d "$check" -p1 -s -f --no-backup-if-mismatch < "$file"
      scratch_git add -A -f
      sed -e '/^\(diff \|--- \)/,$d' "$file" > "${work}/refreshed.patch"
      scratch_git diff --cached --no-ext-diff >> "${work}/refreshed.patch"
      mv "${work}/refreshed.patch" "$file"
      scratch_git commit -q -m "$patch"
      echo "::warning title=${SOURCE} ${patch}::needs fuzz on ${BRANCH}; refreshed here, but the release from it will need it refreshed"
      kept+=("$patch")
    elif patch -d "$check" -p1 -s -f -R --dry-run < "$file" > /dev/null; then
      echo "::warning title=${SOURCE} ${patch}::already in ${BRANCH}; dropped here, but the release from it will need it dropped"
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

# A snapshot adds and drops symbols against the release's symbols file; dpkg-gensymbols still logs the diff.
sed -i '1a export DPKG_GENSYMBOLS_CHECK_LEVEL = 0' "${tree}/debian/rules"

tar -C "$work" -cf "$SOURCE_TAR" "$SOURCE"
