local series = import 'series.libsonnet';

series.rubyDefaults(
  '3.4',
  commit='d4a6e827fc82402bb38386f8f066b4d97e833e7a',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
