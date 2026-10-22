local series = import 'series.libsonnet';

series.ruby(
  '4.0',
  master='master',
  commit='51f86ee24374c9bc4924fbfb7d536e5835bac544',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
