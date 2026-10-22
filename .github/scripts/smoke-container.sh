#!/bin/bash
# Runs inside a stock distro image; the checks follow sorah-rbpkg/test.sh.
# rubygems-integration and ruby-defaults come from the published apt repository.
set -euxo pipefail
: "${DISTRO:?}" "${ARCH:?}" "${RUBY_VERSION:?}"
export DEBIAN_FRONTEND=noninteractive
v="$RUBY_VERSION"

# Same as dockerfiles/Dockerfile.bullseye: deb.debian.org's bullseye-security pool misses files its index lists.
if [[ "$DISTRO" = bullseye ]]; then
  printf '%s\n' \
    'deb http://archive.debian.org/debian bullseye main' \
    'deb http://archive.debian.org/debian bullseye-updates main' \
    'deb http://archive.debian.org/debian-security bullseye-security main' \
    > /etc/apt/sources.list
  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive
fi

apt-get update
apt-get install -y --no-install-recommends ca-certificates
install -D -m0644 /keys/sorah-ruby.gpg /usr/local/share/keyrings/sorah-ruby.gpg
echo "deb [signed-by=/usr/local/share/keyrings/sorah-ruby.gpg] https://cache.ruby-lang.org/lab/sorah/deb/ ${DISTRO} main" \
  > /etc/apt/sources.list.d/sorah-ruby.list
apt-get update

debs=()
for deb in /debs/*_"${ARCH}".deb /debs/*_all.deb; do
  if [[ -e "$deb" && "$deb" != *-dbgsym_* ]]; then
    debs+=("$deb")
  fi
done

# ruby-defaults provides the unsuffixed commands, but only exists for the series it currently points at.
defaults_version="$(apt-cache madison ruby | awk -v prefix="1:${v}+" 'index($3, prefix) == 1 { print $3; exit }')"
defaults=()
sfx="$v"
if [[ -n "$defaults_version" ]]; then
  defaults=("ruby=${defaults_version}" "libruby=${defaults_version}" "ruby-dev=${defaults_version}" "ri=${defaults_version}" "ruby-full=${defaults_version}")
  sfx=
else
  echo "::notice::no ruby-defaults for ${v} in the apt repository; checking suffixed commands only"
fi
apt-get install -y "${debs[@]}" "${defaults[@]}"

"ruby${sfx}" -v
"ruby${sfx}" --enable=yjit --yjit-stats -e0
"gem${sfx}" install aws-sdk-s3 rexml
"ruby${sfx}" -raws-sdk-s3 -e 'p Aws::S3::Client'
"ruby${sfx}" -rnet/http -e0
"irb${sfx}" --version
"rdoc${sfx}" --version
"ri${sfx}" --version
# minitest 6 exits 1 after printing its version.
{ "minitest${v}" --version || true; } | grep '^minitest '
"racc${v}" --version
"rake${sfx}" --version
"rbs${v}" --version
"rdbg${v}" --version
"test-unit${v}" --version
"typeprof${v}" --version
"bundle${sfx}" --version
"erb${sfx}" --version
"syntax_suggest${v}" --version
RUBY_GC_LIBRARY=default "ruby${sfx}" -v
RUBY_GC_LIBRARY=mmtk "ruby${sfx}" -v
