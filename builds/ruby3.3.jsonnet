local series = import 'series.libsonnet';

series.ruby(
  '3.3',
  commit='cccd124402400ec39dcc402fc790145d0e9f65d2',
  // distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
  distros=['bullseye'],
  test=false,
  try=3,
)
