local series = import 'series.libsonnet';

series.ruby(
  '4.0',
  master='master',
  commit='c9c2ead28a5c4c11fbbb2eca0fe6248d3942aef8',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
  try=3,
)
