local series = import 'series.libsonnet';

series.ruby(
  '4.1',
  master='next-4.1',
  commit='de4d689c42ad933e25cd4bedebf4015f25e62e3f',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
)
