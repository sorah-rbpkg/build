{
  ruby(version, commit, distros, master='master-%s' % version, test=true):: {
    source: 'ruby%s' % version,
    repository: 'sorah-rbpkg/ruby',
    master: master,
    commit: commit,
    dist: 'dist/%s' % version,
    distros: distros,
    // The first arch also builds the source and arch:all packages.
    archs: ['amd64', 'arm64'],
    // Every run of a test series releases into test/ of this repository, never the source repository.
    test: test,
  },
}
