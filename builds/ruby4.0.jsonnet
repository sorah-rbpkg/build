local series = import 'series.libsonnet';

series.ruby(
  '4.0',
  master='master',
  commit='4de889346eb34a5b2ff4ab6657961726acabd66a',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
