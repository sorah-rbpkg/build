local series = import 'series.libsonnet';

series.ruby(
  '3.4',
  commit='55eea246b29c400a0631120a910970f02ac80ca6',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
  try=3,
)
