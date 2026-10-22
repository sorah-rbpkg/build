#!/bin/bash
# Runs inside the build image. BUILD=full builds source, arch:any and arch:all; BUILD=any builds arch:any only.
set -euxo pipefail
: "${SOURCE:?}" "${DISTRO:?}" "${BUILD:?}" "${HOST_UID:?}" "${HOST_GID:?}"
# ORIG_NAME is empty for a native package.
ORIG_NAME="${ORIG_NAME:-}"

useradd -o -u "$HOST_UID" -m buildbot
echo buildbot > /etc/mailname

mkdir -p /build
tar -C /build -xf /work/source.tar
if [[ -n "$ORIG_NAME" ]]; then
  cp "/work/${ORIG_NAME}" /build/
fi
chown -R buildbot: /build

cd "/build/${SOURCE}"
# The changelog is written for "~dist"; each distro gets its own version suffix and target suite.
sed -i -e "s/_dist_/${DISTRO}/g" debian/changelog
sed -i -e "s/~dist) unstable; urgency=/~${DISTRO}) ${DISTRO}; urgency=/g" debian/changelog
sed -i -e "s/~dist) unstable-proposed; urgency=/~${DISTRO}) ${DISTRO}-proposed; urgency=/g" debian/changelog
sed -i -e "s/~dist)/~${DISTRO})/g" debian/changelog

runuser -u buildbot -- debuild -us -uc "--build=${BUILD}"

cd /build
cut -d' ' -f1 "${SOURCE}/debian/files" | xargs -I{} cp -v {} /output/
cp -v ./*.changes ./*.buildinfo /output/
if [ "$BUILD" = full ]; then
  if [[ -n "$ORIG_NAME" ]]; then
    cp -v ./*.dsc ./*.debian.tar.* /output/
  else
    cp -v ./*.dsc "./${SOURCE}_"*.tar.* /output/
  fi
fi
chown -R "${HOST_UID}:${HOST_GID}" /output
