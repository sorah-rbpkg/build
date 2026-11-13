local series = import 'series.libsonnet';

series.ruby(
  '4.0',
  master='master',
  commit='e2df406c3fbb8de148ea4569841c51235d9cf23f',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
  try=3,
)
