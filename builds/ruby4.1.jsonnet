local series = import 'series.libsonnet';

series.ruby(
  '4.1',
  master='next-4.1',
  commit='d3e7e87d0bf167c9804e4bcda390a317edf1b284',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
  // ruby/ruby@d76d518b7f
  nightly_drop=['test_gem_credential_store_-run-fake-backends-with-Gem.rub.patch'],
)
