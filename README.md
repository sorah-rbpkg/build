# sorah-rbpkg/build: GitHub Actions pipeline for the sorah-rbpkg Ruby packages

This repository builds the Debian packages of [sorah-rbpkg/ruby](https://github.com/sorah-rbpkg/ruby) for every supported Debian and Ubuntu release, on amd64 and arm64. Built packages are smoke tested and attested, and wait for a human approval before anything is pushed to sorah-rbpkg/ruby. It replaces the local [`sorah-debuild`](https://github.com/sorah/config/blob/master/bin/sorah-debuild) scripts, and the packages it produces end up in the apt repository at `https://cache.ruby-lang.org/lab/sorah/deb/`.

## Usage

### Releasing a new version

Import the release into your checkout of sorah-rbpkg/ruby, `../ruby` by default, review it, and push it:

```
bin/import 4.0.9 3.4.12                      # one version per series
bin/import --push 4.0.9 3.4.12
bin/import --ahead pristine-tar=<SHA> 3.3.13  # on top of an earlier import not yet pushed
bin/import --branch 4.1=next-4.1 4.1.0-preview2  # a series not on master or master-N.M
```

Then point the series at the release, check the commits, and push them to `main` here, which starts the build:

```
bin/roll master                              # the series on master, at its tip on GitHub
bin/roll master master-3.4 master-3.3        # several series at once
bin/roll <full SHA>                          # a given commit
git push
```

Approve each distro's release job, then publish the drafts, which also updates `versions.json` of [sorah-rbpkg/dockerfiles](https://github.com/sorah-rbpkg/dockerfiles):

```
bin/publish                                  # every draft on the repositories under builds/
bin/publish --repository sorah-rbpkg/ruby    # only those of one repository
bin/publish debian/4.0.8-0nkmi1_noble        # only this one
bin/publish --dry-run                        # only verify; changes nothing
bin/publish --no-publish                     # stop after re-signing
bin/publish --relay-only                     # only update sorah-rbpkg/dockerfiles
```

[docs/tools.md](./docs/tools.md) describes what each of them checks and changes, and where `bin/publish` gets its token.

### Releasing ruby-defaults and rubygems-integration

[sorah-rbpkg/ruby-defaults](https://github.com/sorah-rbpkg/ruby-defaults) and [sorah-rbpkg/rubygems-integration](https://github.com/sorah-rbpkg/rubygems-integration) are native packages, built without an orig tarball. ruby-defaults has one series per default Ruby, `builds/ruby-defaults<N.M>.jsonnet`, each built from its own branch; rubygems-integration has one, built from `master`. Commit the changelog entry with a `~dist` version to that branch, push it, and roll it like any other series:

```
bin/roll --repository sorah-rbpkg/ruby-defaults master master-3.4
bin/roll --repository sorah-rbpkg/rubygems-integration master
```

### Proposed packages

A series with `proposed: true` publishes into `<distro>-proposed` of the apt repository, such as a preview Ruby on `next-N.M` or a rubygems-integration update that needs trying first. Its changelog still targets `unstable`. Roll and publish it as usual: its releases stay pre-releases, which sorah-rbpkg/dockerfiles ignores. Once it has been tried, copy the same packages into `<distro>`, without a rebuild:

```
bin/promote debian/1.20.1nkmi1_noble         # copies into noble, then marks the release as released
bin/promote --dry-run debian/1.20.1nkmi1_noble
```

### Handling failed builds

- A flaky job: re-run the failed jobs of the run.
- A hung build: the debuild step kills itself after `quiet_seconds` in `watchdog.json` without output. To kill one sooner, add the `JOB_ID RUN_ATTEMPT` line its debuild step prints to `kills.txt` and push. Running builds read both files from `main` every minute.
- A packaging fix: commit it to `master`, then `bin/roll <branch>` and push. Only distros without a `debian/` tag are built again.
- A deliberate rebuild: bump `try` in `builds/<series>.jsonnet` and push, or run the `build` workflow by hand with `series` and optionally `distros`. Either way, only distros without a `debian/` tag are built unless the run is in test mode.

A push builds a series only when its `commit`, `try`, `distros` or `test` changes, or when the series is new. Changing any other field, such as `smoke`, builds nothing until one of those changes too.

### Test mode

A series with `"test": true`, or a `build` run started by hand with `test` checked, goes through every job, approval included, but releases into `test/` of this repository instead of the source repository. See [docs/test-mode.md](./docs/test-mode.md).

### Nightly packages

[`nightly.yml`](./.github/workflows/nightly.yml) builds every `rubyN.M` series, except proposed ones, from the snapshot of its `ruby_N_M` branch each Monday, as `<X.Y.Z>+git<YYYYMMDD>.g<commit>-0nkmi0~<distro>`. The packages stay as artifacts of the run for 90 days, and those that pass smoke become the `N.M.next` images of sorah-rbpkg/dockerfiles. See [docs/nightly.md](./docs/nightly.md).

## Documentation

- [docs/architecture.md](./docs/architecture.md): what each workflow and job does, and caveats
- [docs/tools.md](./docs/tools.md): `bin/import`, `bin/roll`, `bin/publish` and `bin/promote` in detail
- [docs/test-mode.md](./docs/test-mode.md): test runs and cleaning up after them
- [docs/nightly.md](./docs/nightly.md): nightly packages and their roll into sorah-rbpkg/dockerfiles
- [docs/ruby-defaults.md](./docs/ruby-defaults.md): the Rubies ruby-defaults lists per series and distro, kept on its dist branches
- [docs/setup.md](./docs/setup.md): one-time setup and local tools

## Configuration

Each series has its own `builds/<series>.jsonnet`, which `bin/generate` renders with jrsonnet into `gen/builds/<series>.json`, the file the workflows read. `builds/series.libsonnet` holds the defaults they share. `hk check` fails when the two disagree.

```jsonc
// gen/builds/ruby4.0.json
{
  "source": "ruby4.0",                  // Source: in debian/control
  "repository": "sorah-rbpkg/ruby",
  "master": "master",                   // commit must be reachable from this branch
  "commit": "<full SHA>",               // the release to build
  "dist": "dist/4.0",                   // branches are dist/4.0/<distro>
  "distros": ["jammy", "noble", "resolute", "bookworm", "trixie"],
  "archs": ["amd64", "arm64"],          // the first one also builds source and arch:all packages
  "smoke": "ruby",                      // .github/scripts/smoke/<smoke>.sh
  "proposed": false,                    // publishes into <distro>-proposed; see Proposed packages
  "test": true,                         // every run is a test run; see docs/test-mode.md
  "try": 2                              // optional; bumping it rebuilds on push to main
}
```

`bin/plan gen/builds/ruby4.0.json` shows locally what a push would build.

## Security model

- Only a `commit` signed by a key in `keys/committers.asc` is built, test runs included. The `upstream/<version>` tag the orig tarball comes from must be signed by such a key as well, and its files must match the ruby-lang.org release tarball, whose sha256 is taken from [ruby/www.ruby-lang.org](https://github.com/ruby/www.ruby-lang.org/blob/master/_data/releases.yml). Adding a signer means committing their public key there.
- Only the `release` job of `_distro.yml` on `main`, after approval, can obtain a token for sorah-rbpkg/ruby. Build and smoke jobs have read access only.
- The release job pushes without force, so `dist/N.M/<distro>` only ever fast-forwards, and it refuses a tag that already points elsewhere.
- The merge commits on `dist/N.M/<distro>` and the `debian/` tags CI pushes are signed keylessly by gitsign with the identity of `_distro.yml` on `main`. `bin/publish` re-signs the tag with your GPG key but leaves the commit as is, so a released tag records who released it and the commit it points at records that CI made it. GitHub shows gitsign signatures as unverified, because the Sigstore CA is not in its trust store; check them with `gitsign verify --certificate-identity=https://github.com/sorah-rbpkg/build/.github/workflows/_distro.yml@refs/heads/main --certificate-oidc-issuer=https://token.actions.githubusercontent.com <commit>`.
- Every built file carries a GitHub build provenance attestation. `bin/publish` checks them before it signs anything with your key, so a released tag and `.changes` carry your signature only for files CI is proven to have built.
- Nightly packages are never signed or released, and nobody reviews them. Their orig is the ruby-lang.org snapshot, trusted through HTTPS and the sha256 next to it, and their `debian/` comes from the released dist branches. They carry build provenance attestations from `nightly.yml`, which sorah-rbpkg/dockerfiles verifies before building `N.M.next`.

## Setup

[docs/setup.md](./docs/setup.md) covers the environments, secrets and sts-cat trust policies, done once for sorah-rbpkg, and the local tools.

## Prior art

- [sorah-debuild](https://github.com/sorah/config/blob/master/bin/sorah-debuild), [sorah-debuild-auto](https://github.com/sorah/config/blob/master/bin/sorah-debuild-auto) and [sorah-debuild-codebuild](https://github.com/sorah/config/blob/master/bin/sorah-debuild-codebuild), the local build scripts this replaces
- [sorah-deb-release](https://github.com/sorah/config/blob/master/bin/sorah-deb-release), which `bin/publish` is derived from
- [sts-cat](https://github.com/sorah/sts-cat), for cross-repository tokens

## License

MIT License. See [LICENSE](./LICENSE).
