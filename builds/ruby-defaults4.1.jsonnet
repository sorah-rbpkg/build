local series = import 'series.libsonnet';

series.rubyDefaults(
  '4.1',
  master='next-4.1',
  commit='318da01fdd73f5fc05ca7a18c860d9fb52b55ddb',
  distros=['noble', 'resolute', 'trixie'],
  proposed=true,
  test=false,
)
