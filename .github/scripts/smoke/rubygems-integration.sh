#!/bin/bash
# Installs a rubygems-integration build, with ruby from the published apt repository.
set -euxo pipefail
# shellcheck disable=SC1091
. /smoke/lib.sh
mapfile -t debs < <(built_debs)
apt-get install -y "${debs[@]}" ruby

# Where Debian's gem packages install, which rubygems learns from this package.
ruby -e 'dir = "/usr/share/rubygems-integration/all"; abort "#{dir} is not in #{Gem.path}" unless Gem.path.include?(dir)'
gem list
