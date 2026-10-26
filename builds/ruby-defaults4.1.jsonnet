local series = import 'series.libsonnet';

series.rubyDefaults(
  '4.1',
  master='next-4.1',
  commit='1a05c26b260716d3a74c095b1733a83180f5495d',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
)
