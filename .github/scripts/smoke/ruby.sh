#!/bin/bash
# Installs a rubyN.M build; the checks follow sorah-rbpkg/test.sh.
# rubygems-integration and ruby-defaults come from the published apt repository.
set -euxo pipefail
: "${SOURCE:?}"
# shellcheck disable=SC1091
. /smoke/lib.sh
mapfile -t debs < <(built_debs)
v="${SOURCE#ruby}"

# ruby-defaults provides the unsuffixed commands, but only exists for the series it currently points at.
# The distro's own ruby-defaults can be of the same series, as on trixie.
defaults_version="$(apt-cache madison ruby | awk -v prefix="1:${v}+" 'index($3, prefix) == 1 && /cache\.ruby-lang\.org/ { print $3; exit }')"
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
# Built with ZJIT from 4.1.
if "ruby${sfx}" -e 'exit defined?(RubyVM::ZJIT) ? 0 : 1'; then
  "ruby${sfx}" --zjit --zjit-stats -e0
fi
"gem${sfx}" install aws-sdk-s3 rexml
"ruby${sfx}" -raws-sdk-s3 -e 'p Aws::S3::Client'
"ruby${sfx}" -rnet/http -e0
"irb${sfx}" --version
"rdoc${sfx}" --version
"ri${sfx}" --version
# The minitest and test-unit bundled before Ruby 4.0 ship no executable.
has_executable() {
  "ruby${sfx}" -e 'exit Gem::Specification.find_by_name(ARGV[0]).executables.include?(ARGV[0])' "$1"
}
if has_executable minitest; then
  # minitest 6 exits 1 after printing its version.
  { "minitest${v}" --version || true; } | grep '^minitest '
fi
"racc${v}" --version
"rake${sfx}" --version
"rbs${v}" --version
"rdbg${v}" --version
if has_executable test-unit; then
  "test-unit${v}" --version
fi
"typeprof${v}" --version
"bundle${sfx}" --version
"erb${sfx}" --version
"syntax_suggest${v}" --version
RUBY_GC_LIBRARY=default "ruby${sfx}" -v
RUBY_GC_LIBRARY=mmtk "ruby${sfx}" -v
