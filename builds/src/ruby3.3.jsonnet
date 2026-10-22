local series = import '../lib/series.libsonnet';

series.ruby(
  '3.3',
  commit='05f028301e9299d1f009723e5e65d01fcb5a7929',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
)
