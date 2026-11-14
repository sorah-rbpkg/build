local series = import 'series.libsonnet';

series.ruby(
  '4.1',
  master='next-4.1',
  commit='f690b59b5de917a4006264a187b9efc42a42ea9b',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
  // ruby/ruby@d76d518b7f
  nightly_drop=['test_gem_credential_store_-run-fake-backends-with-Gem.rub.patch'],
)
