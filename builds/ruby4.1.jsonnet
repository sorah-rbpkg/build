local series = import 'series.libsonnet';

series.ruby(
  '4.1',
  master='next-4.1',
  commit='d3e7e87d0bf167c9804e4bcda390a317edf1b284',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
)
