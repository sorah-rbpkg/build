local series(source, repository, master, commit, dist, distros, archs, smoke, large_runner, test, try) = {
  source: source,
  repository: repository,
  master: master,
  commit: commit,
  dist: dist,
  distros: distros,
  // The first arch also builds the source and arch:all packages.
  archs: archs,
  // .github/scripts/smoke/<smoke>.sh
  smoke: smoke,
  large_runner: large_runner,
  // Every run of a test series releases into test/ of this repository, never the source repository.
  test: test,
} + (
  // Bumped to rebuild through a push to main without changing anything else.
  if try == null then {} else { try: try }
);

{
  ruby(version, commit, distros, master=null, test=true, try=null)::
    series(
      source='ruby%s' % version,
      repository='sorah-rbpkg/ruby',
      master=if master == null then 'master-%s' % version else master,
      commit=commit,
      dist='dist/%s' % version,
      distros=distros,
      archs=['amd64', 'arm64'],
      smoke='ruby',
      // Ruby's test suite needs the org's large runners; other packages build on standard ones.
      large_runner=true,
      test=test,
      try=try,
    ),

  // One series per default Ruby, each on its own branch.
  rubyDefaults(version, commit, distros, master=null, test=true, try=null)::
    series(
      source='ruby-defaults',
      repository='sorah-rbpkg/ruby-defaults',
      master=if master == null then 'master-%s' % version else master,
      commit=commit,
      dist='dist/%s' % version,
      distros=distros,
      archs=['amd64', 'arm64'],
      smoke='ruby-defaults',
      large_runner=false,
      test=test,
      try=try,
    ),

  rubygemsIntegration(commit, distros, test=true, try=null)::
    series(
      source='rubygems-integration',
      repository='sorah-rbpkg/rubygems-integration',
      master='master',
      commit=commit,
      dist='dist',
      distros=distros,
      // arch:all only, so a second arch would have nothing to build.
      archs=['amd64'],
      smoke='rubygems-integration',
      large_runner=false,
      test=test,
      try=try,
    ),
}
