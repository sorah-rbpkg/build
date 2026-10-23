local series = import 'series.libsonnet';

series.ruby(
  '3.4',
  commit='0706bcd9de4a21703163f83c3a95e9f9e86c3dd8',
  distros=['jammy', 'noble', 'resolute', 'bookworm', 'trixie'],
  test=false,
)
