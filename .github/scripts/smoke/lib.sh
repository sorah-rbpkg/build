#!/bin/bash
# Sourced by each smoke script, inside a stock image of DISTRO. Adds the published apt repository.
: "${DISTRO:?}" "${SUITE:?}" "${ARCH:?}"
export DEBIAN_FRONTEND=noninteractive

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
# A proposed package may depend on others only in its suite, such as a ruby-defaults on its rubyN.M.
for suite in $(printf '%s\n' "$DISTRO" "$SUITE" | uniq); do
  echo "deb [signed-by=/usr/local/share/keyrings/sorah-ruby.gpg] https://cache.ruby-lang.org/lab/sorah/deb/ ${suite} main"
done > /etc/apt/sources.list.d/sorah-ruby.list
apt-get update

# Prints the built packages for ARCH, without debug symbols.
built_debs() {
  local deb
  for deb in /debs/*_"${ARCH}".deb /debs/*_all.deb; do
    if [[ -e "$deb" && "$deb" != *-dbgsym_* ]]; then
      echo "$deb"
    fi
  done
}
