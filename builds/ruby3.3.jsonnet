local series = import 'series.libsonnet';

series.ruby(
  '3.3',
  commit='3fc94452ce01b67fb3679971d5e46915de52ea03',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
)
