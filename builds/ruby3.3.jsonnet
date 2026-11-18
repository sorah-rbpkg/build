local series = import 'series.libsonnet';

series.ruby(
  '3.3',
  commit='891bde599ebcc75bc745204c05dbe2512dfd57dd',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
  test=false,
  try=5,
  releases_pr=4069,
)
