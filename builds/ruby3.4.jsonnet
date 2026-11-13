local series = import 'series.libsonnet';

series.ruby(
  '3.4',
  commit='26c191a899358b44cf82a2e5fc3b479d9c409635',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
  try=3,
)
