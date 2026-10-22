local series = import 'series.libsonnet';

series.ruby(
  '3.4',
  commit='08ad1d5e783e043d09d91de2d8f84c6f719b9300',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
)
