local series = import 'series.libsonnet';

series.rubyDefaults(
  '4.0',
  master='master',
  commit='d9c49857c3c6ba850f7355992f5a38fddfd3eb62',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
)
