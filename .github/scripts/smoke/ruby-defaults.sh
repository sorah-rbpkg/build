#!/bin/bash
# Installs a ruby-defaults build, with the rubyN.M it points at from the published apt repository.
set -euxo pipefail
# shellcheck disable=SC1091
. /smoke/lib.sh
# ruby-all-dev depends on every Ruby ruby_debian_dev.rb supports, which the apt repository may lack for DISTRO.
mapfile -t debs < <(built_debs | grep -v '/ruby-all-dev_')
apt-get install -y "${debs[@]}" pkg-config

# 1:4.0+0nkmi1~noble points at Ruby 4.0.
series="$(dpkg-query -W -f '${Version}' ruby | sed -e 's/^[0-9]*://' -e 's/+.*//')"
ruby -e 'abort "ruby is #{RUBY_VERSION}, not #{ARGV[0]}" unless RUBY_VERSION.start_with?("#{ARGV[0]}.")' "$series"
# debian/rules DEBIAN_RUBY_PROGRAMS
for program in erb gem irb rdoc ri ruby rake bundle; do
  "/usr/bin/${program}" --version
done
pkg-config --cflags --libs ruby
