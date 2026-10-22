local series = import 'series.libsonnet';

series.rubyDefaults(
  '4.0',
  master='master',
  commit='7ed5a39ed6385420eac0de72b2eeb9b328c2fa56',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
