local series = import 'series.libsonnet';

series.ruby(
  '3.3',
  commit='1948ca3758566608db371090def9b8939e7146eb',
  // distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
  distros=['bullseye'],
  test=false,
  try=3,
)
