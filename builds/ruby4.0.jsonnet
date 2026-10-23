local series = import 'series.libsonnet';

series.ruby(
  '4.0',
  master='master',
  commit='bebc88559e74d908d6d20bcaec71f5c7c955d21c',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
)
