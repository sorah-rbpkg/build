local series = import 'series.libsonnet';

series.ruby(
  '4.1',
  master='next-4.1',
  commit='f01081914ef6f981bc9574e60f8ac61512f685d5',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
)
