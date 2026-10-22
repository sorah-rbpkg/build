local series = import 'series.libsonnet';

series.rubyDefaults(
  '3.3',
  commit='97625eed944432ec119c019d0bd54dbe337f94dc',
  distros=['focal', 'jammy', 'noble', 'bullseye', 'bookworm', 'trixie'],
)
