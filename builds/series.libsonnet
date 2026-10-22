{
  ruby(version, commit, distros, master=null, test=true, try=null):: {
    source: 'ruby%s' % version,
    repository: 'sorah-rbpkg/ruby',
    master: if master == null then 'master-%s' % version else master,
    commit: commit,
    dist: 'dist/%s' % version,
    distros: distros,
    // The first arch also builds the source and arch:all packages.
    archs: ['amd64', 'arm64'],
    // .github/scripts/smoke/<smoke>.sh
    smoke: 'ruby',
    // Ruby's test suite needs the org's large runners; other packages build on standard ones.
    large_runner: true,
    // Every run of a test series releases into test/ of this repository, never the source repository.
    test: test,
  } + (
    // Bumped to rebuild through a push to main without changing anything else.
    if try == null then {} else { try: try }
  ),
}
