local series = import 'series.libsonnet';

series.rubygemsIntegration(
  master='next',
  commit='92f753ba65ab97f7b161886ef78f261ad4379f49',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  proposed=true,
  test=false,
)
