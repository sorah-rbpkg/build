local series = import 'series.libsonnet';

series.ruby(
  '4.1',
  master='next-4.1',
  commit='6d5ec660ec15be26e3aaecfdc6f1e3d79aa67f30',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
  // ruby/ruby@d76d518b7f
  nightly_drop=['test_gem_credential_store_-run-fake-backends-with-Gem.rub.patch'],
)
