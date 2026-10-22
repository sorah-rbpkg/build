local series = import 'series.libsonnet';

series.rubygemsIntegration(
  commit='91eb3f1bab34542d743b2768258fe31e5bd291f4',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
