local series = import 'series.libsonnet';

series.ruby(
  '4.0',
  master='master',
  commit='726e8f77dcab4489fec2a85c0d061c6d0e232daa',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
  try=4,
)
