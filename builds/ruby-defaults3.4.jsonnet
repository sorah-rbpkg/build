local series = import 'series.libsonnet';

series.rubyDefaults(
  '3.4',
  commit='2a396637660a4d19eb02702c5780035cb3ecb286',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
)
