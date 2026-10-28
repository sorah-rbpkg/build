local series = import 'series.libsonnet';

series.rubyDefaults(
  '3.3',
  commit='fb0f35e77834d78d735f15ae1033c61ff8111333',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
  test=false,
)
