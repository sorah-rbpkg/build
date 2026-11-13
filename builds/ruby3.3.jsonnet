local series = import 'series.libsonnet';

series.ruby(
  '3.3',
  commit='c181f85e5b2bce93f6a59fd7644a3a2dbc515ba9',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
  test=false,
  try=5,
)
