# Test mode

A series with `"test": true` runs every build in test mode, including those started by a push. Series start that way, and real releases begin with a reviewed change to `false`. Running the `build` workflow by hand with `test` checked does the same for one run.

A test run goes through every job, approval included, without writing to sorah-rbpkg/ruby:

- Distros are built even when already released, so a released version can serve as the test subject.
- The release job obtains no sts-cat token. It pushes `test/<repo>/dist/N.M/<distro>` and `test/<repo>/debian/<version>_<distro>` to this repository, where `<repo>` names the source repository, and creates the draft release here. A later test run replaces them.
- The stage branch is named `test/<repo>/dist-stage/...`.

`bin/publish --test` verifies and re-signs those drafts with the token of your `gh` login, and never runs aptly or publishes. `bin/cleanup-test` deletes every `test/` release, tag and branch, so the next test run starts from scratch. It refuses while a `build` run is active; `--dry-run` lists what it would delete.
