local series = import 'series.libsonnet';

series.ruby(
  '3.3',
  commit='baab9d262584bdda7455250183058590af7e19a1',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
)
