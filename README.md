# sorah-rbpkg/build: GitHub Actions pipeline for the sorah-rbpkg Ruby packages

This repository builds the Debian packages of [sorah-rbpkg/ruby](https://github.com/sorah-rbpkg/ruby) for every supported Debian and Ubuntu release, on amd64 and arm64. Built packages are smoke tested and attested, and wait for a human approval before anything is pushed to sorah-rbpkg/ruby. It replaces the local [`sorah-debuild`](https://github.com/sorah/config/blob/master/bin/sorah-debuild) scripts, and the packages it produces end up in the apt repository at `https://cache.ruby-lang.org/lab/sorah/deb/`.

## How it works

1. A release is prepared on `master` (or `master-N.M`) of sorah-rbpkg/ruby with `gbp import-orig` and pushed.
2. `commit` in [`builds/<series>.jsonnet`](./builds) is pointed at that commit and pushed to `main` here.
3. [`build.yml`](./.github/workflows/build.yml) runs [`bin/plan`](./bin/plan), which checks that the commit is signed by a key in [`keys/committers.asc`](./keys/committers.asc) and lists the distros whose `debian/<version>_<distro>` tag does not exist yet.
4. The orig tarball is generated once per run from the commit of the signed `upstream/<version>` tag, checked against the ruby-lang.org release by [`bin/verify-orig`](./bin/verify-orig), and compared with any copy already in the apt repository, whose pool rejects a second orig with different bytes. Every distro in the run builds from that one file, and each distro's release carries it.
5. [`_distro.yml`](./.github/workflows/_distro.yml) runs once per distro:
   - merge: merges the commit into `dist/N.M/<distro>` and stages the result here as `dist-stage/N.M/<distro>`
   - build: runs `debuild` in the image from [`dockerfiles/Dockerfile.<distro>`](./dockerfiles), or `dockerfiles/N.M/Dockerfile.<distro>` when a series needs its own, with the package's `debian/control` as its build dependencies, on native amd64 and arm64 runners, and attests every output
   - smoke: installs the packages on a stock image of the distro and runs the interpreter and bundled tools
   - release: waits for approval in the `release` environment, tags `debian/<version>_<distro>` with gitsign, fast-forwards `dist/N.M/<distro>` on sorah-rbpkg/ruby, and uploads everything to a draft release there, with links to the build attestations
6. [`bin/publish`](./bin/publish), run locally, verifies the draft, re-signs it with your GPG key, adds it to aptly and publishes the release.

Distros are independent: one failing distro never blocks the release of another, and no run cancels another.

## Setup

### 1. Configure this repository

Create the `release` environment with a required reviewer and the secret `STS_CAT_ENDPOINT`.

### 2. Allow the release job to write sorah-rbpkg/ruby

The release job obtains its token from [sts-cat](https://github.com/sorah/sts-cat). Add an org-level trust policy:

```toml
# sorah-rbpkg/.github: .github/sts-cat/build.sts.toml
issuer = "https://token.actions.githubusercontent.com"
subject = "repo:sorah-rbpkg@19392696/build@1429643459:environment:release"
repositories = ["ruby"]
max_token_lifetime = 3600

[claim_pattern]
job_workflow_ref = "sorah-rbpkg/build/\\.github/workflows/_distro\\.yml@refs/heads/main"

[permissions]
contents = "write"
```

### 3. Prepare the local tools

```
mise install
hk install
```

`hk check --all` runs the same checks as CI. `bin/publish` additionally needs `gpg`, [`sorah-debsign`](https://github.com/sorah/config/blob/master/bin/sorah-debsign) on `PATH`, and an `aptly` configured with the `sorah-ruby-<distro>` repositories and the `s3:sorah-ruby:` endpoint.

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
  "test": true,                         // every run is a test run; see Test mode
  "try": 2                              // optional; bumping it rebuilds on push to main
}
```

`bin/plan gen/builds/ruby4.0.json` shows locally what a push would build.

## Usage

### Releasing a new version

Point the series at the release, check the commits, and push them to `main`, which starts the build:

```
bin/roll master                              # the series on master, at its tip on GitHub
bin/roll master master-3.4 master-3.3        # several series at once
bin/roll <full SHA>                          # a given commit
git push
```

`bin/roll` reads the source package from `debian/changelog` at each revision to find its series, sets `commit` in `builds/<series>.jsonnet`, and runs `bin/generate`. It checks every series with `bin/plan` before committing any, then commits each as `roll <series> <version>`. It first makes sure your checkout of sorah-rbpkg/ruby, `../ruby` by default, has pushed each branch and its `upstream/<version>` tag. Approve each distro's release job, then publish the drafts:

```
bin/publish                                  # every draft on sorah-rbpkg/ruby
bin/publish debian/4.0.8-0nkmi1_noble        # only this one
bin/publish --no-publish                     # stop after re-signing
```

`bin/publish` works through each draft in three steps, skipping any that is already done, so a failed run can be repeated:

1. Verifies the gitsign signature of the tag against `_distro.yml` on `main`, that the tag is on `dist/N.M/<distro>`, the build attestation of every asset, and the checksums in the `.changes` and `.dsc`.
2. Re-signs the tag with `git tag -s`, and the `.changes`, `.dsc` and `.buildinfo` with `sorah-debsign`, then replaces them on the draft.
3. Runs `aptly repo add` and `aptly publish update`, then publishes the release.

Its GitHub token comes from `GH_TOKEN`, or from sts-cat through the `DebReleaser` role:

```jsonc
// ~/.nkmi-deb-release.json
{
  "stscat_url": "https://sts-cat.example.com",
  "stscat_audience": "https://sts-cat.nkmi.me"
}
```

### Handling failed builds

- A flaky job: re-run the failed jobs of the run.
- A packaging fix: commit it to `master`, then `bin/roll <branch>` and push. Only distros without a `debian/` tag are built again.
- A deliberate rebuild: bump `try` in `builds/<series>.jsonnet` and push, or run the `build` workflow by hand with `series` and optionally `distros`. Either way, only distros without a `debian/` tag are built unless the run is in test mode.

### Test mode

A series with `"test": true` runs every build in test mode, including those started by a push. Series start that way, and real releases begin with a reviewed change to `false`. Running the `build` workflow by hand with `test` checked does the same for one run.

A test run goes through every job, approval included, without writing to sorah-rbpkg/ruby:

- Distros are built even when already released, so a released version can serve as the test subject.
- The release job obtains no sts-cat token. It pushes `test/dist/N.M/<distro>` and `test/debian/<version>_<distro>` to this repository and creates the draft release here. A later test run replaces them.
- The stage branch is named `test/dist-stage/...`.

`bin/publish --test` verifies and re-signs those drafts with the token of your `gh` login, and never runs aptly or publishes. `bin/cleanup-test` deletes every `test/` release, tag and branch, so the next test run starts from scratch. It refuses while a `build` run is active; `--dry-run` lists what it would delete.

## Security model

- Only a `commit` signed by a key in `keys/committers.asc` is built, test runs included. The `upstream/<version>` tag the orig tarball comes from must be signed by such a key as well, and its files must match the ruby-lang.org release tarball, whose sha256 is taken from [ruby/www.ruby-lang.org](https://github.com/ruby/www.ruby-lang.org/blob/master/_data/releases.yml). Adding a signer means committing their public key there.
- Only the `release` job of `_distro.yml` on `main`, after approval, can obtain a token for sorah-rbpkg/ruby. Build and smoke jobs have read access only.
- The release job pushes without force, so `dist/N.M/<distro>` only ever fast-forwards, and it refuses a tag that already points elsewhere.
- Tags pushed by CI are signed keylessly by gitsign with the workflow's identity. GitHub shows them as unverified, because the Sigstore CA is not in its trust store.
- Every built file carries a GitHub build provenance attestation. `bin/publish` checks them before it signs anything with your key, so a released tag and `.changes` carry your signature only for files CI is proven to have built.

## Caveats

- A distro needs its `dist/N.M/<distro>` branch on sorah-rbpkg/ruby and a [`dockerfiles/Dockerfile.<distro>`](./dockerfiles) here before it can be added to a series.
- The orig tarball is regenerated by every run, relying on `git archive` and `gzip -n` producing the same bytes. If a later git or gzip ever changes that, the run fails on the comparison with the apt repository's copy.
- GitHub replaces `~` in release asset names with `.`; `bin/publish` restores the original names after downloading.

## Prior art

- [sorah-debuild](https://github.com/sorah/config/blob/master/bin/sorah-debuild), [sorah-debuild-auto](https://github.com/sorah/config/blob/master/bin/sorah-debuild-auto) and [sorah-debuild-codebuild](https://github.com/sorah/config/blob/master/bin/sorah-debuild-codebuild), the local build scripts this replaces
- [sorah-deb-release](https://github.com/sorah/config/blob/master/bin/sorah-deb-release), which `bin/publish` is derived from
- [sts-cat](https://github.com/sorah/sts-cat), for cross-repository tokens

## License

MIT License. See [LICENSE](./LICENSE).
