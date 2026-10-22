local series = import '../lib/series.libsonnet';

series.ruby(
  '3.4',
  commit='538bb7b2b85c0069f7d38a4a1420faa0b7d2b0a6',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
