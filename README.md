# sorah-rbpkg/build: GitHub Actions pipeline for the sorah-rbpkg Ruby packages

This repository builds the Debian packages of [sorah-rbpkg/ruby](https://github.com/sorah-rbpkg/ruby) for every supported Debian and Ubuntu release, on amd64 and arm64. Built packages are smoke tested and attested, and wait for a human approval before anything is pushed to sorah-rbpkg/ruby. It replaces the local [`sorah-debuild`](https://github.com/sorah/config/blob/master/bin/sorah-debuild) scripts, and the packages it produces end up in the apt repository at `https://cache.ruby-lang.org/lab/sorah/deb/`.

## How it works

1. A release is prepared on `master` (or `master-N.M`) of sorah-rbpkg/ruby with `gbp import-orig` and pushed.
2. `commit` in [`builds/<series>.json`](./builds) is pointed at that commit and pushed to `main` here.
3. [`build.yml`](./.github/workflows/build.yml) runs [`bin/plan`](./bin/plan), which checks that the commit is signed by a key in [`keys/committers.asc`](./keys/committers.asc) and lists the distros whose `debian/<version>_<distro>` tag does not exist yet.
4. The orig tarball is generated once per upstream version from the commit of the signed `upstream/<version>` tag, and kept as the release `orig/<source>/<version>` of this repository, so every distro and every later build use the same bytes.
5. [`_distro.yml`](./.github/workflows/_distro.yml) runs once per distro:
   - merge: merges the commit into `dist/N.M/<distro>` and stages the result here as `dist-stage/N.M/<distro>`
   - build: runs `debuild` in the package's `debian/Dockerfile.<distro>` on native amd64 and arm64 runners, and attests every output
   - smoke: installs the packages on a stock image of the distro and runs the interpreter and bundled tools
   - release: waits for approval in the `release` environment, tags `debian/<version>_<distro>` with gitsign, fast-forwards `dist/N.M/<distro>` on sorah-rbpkg/ruby, and uploads everything to a draft release there
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

Each series has its own `builds/<series>.json`, rendered from `builds/src/<series>.jsonnet` by `bin/generate` with jrsonnet. `hk check` fails when the two disagree.

```jsonc
// builds/ruby4.0.json
{
  "source": "ruby4.0",                  // Source: in debian/control
  "repository": "sorah-rbpkg/ruby",
  "master": "master",                   // commit must be reachable from this branch
  "commit": "<full SHA>",               // the release to build
  "dist": "dist/4.0",                   // branches are dist/4.0/<distro>
  "distros": ["jammy", "noble", "resolute", "bookworm", "trixie"],
  "archs": ["amd64", "arm64"],          // the first one also builds source and arch:all packages
  "test": true                          // every run is a test run; see Test mode
}
```

`bin/plan builds/ruby4.0.json` shows locally what a push would build.

## Usage

### Releasing a new version

Bump `commit` in `builds/src/<series>.jsonnet`, run `bin/generate`, and push to `main`. Approve each distro's release job, then publish the drafts:

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
- A packaging fix: commit it to `master`, bump `commit`, push. Only distros without a `debian/` tag are built again.
- A deliberate rebuild: run the `build` workflow by hand with `series` and optionally `distros`.

### Test mode

A series with `"test": true` runs every build in test mode, including those started by a push. Series start that way, and real releases begin with a reviewed change to `false`. Running the `build` workflow by hand with `test` checked does the same for one run.

A test run goes through every job, approval included, without writing to sorah-rbpkg/ruby:

- Distros are built even when already released, so a released version can serve as the test subject.
- The release job obtains no sts-cat token. It pushes `test/dist/N.M/<distro>` and `test/debian/<version>_<distro>` to this repository and creates the draft release here. A later test run replaces them.
- The orig tarball and stage branch are named `test/orig/...` and `test/dist-stage/...`, so a test never supplies the orig of a real build.

`bin/publish --test` verifies and re-signs those drafts, and never runs aptly or publishes. Clean up with `gh release delete --cleanup-tag` on the test releases and by deleting the `test/` branches.

## Security model

- Only a `commit` signed by a key in `keys/committers.asc` is built, test runs included. The `upstream/<version>` tag the orig tarball comes from must be signed by such a key as well. Adding a signer means committing their public key there.
- Only the `release` job of `_distro.yml` on `main`, after approval, can obtain a token for sorah-rbpkg/ruby. Build and smoke jobs have read access only.
- The release job pushes without force, so `dist/N.M/<distro>` only ever fast-forwards, and it refuses a tag that already points elsewhere.
- Tags pushed by CI are signed keylessly by gitsign with the workflow's identity. GitHub shows them as unverified, because the Sigstore CA is not in its trust store.
- Every built file carries a GitHub build provenance attestation. `bin/publish` checks them before it signs anything with your key, so a released tag and `.changes` carry your signature only for files CI is proven to have built.

## Caveats

- A distro needs its `dist/N.M/<distro>` branch on sorah-rbpkg/ruby before it can be added to a series.
- An orig tarball already in the apt repository must be uploaded as `orig/<source>/<version>` here before CI builds that version. Otherwise CI generates its own, which aptly rejects for having different bytes.
- GitHub replaces `~` in release asset names with `.`; `bin/publish` restores the original names after downloading.
- The package Dockerfiles use the `ap-northeast-1` EC2 apt mirror, which is slower from GitHub-hosted runners.

## Prior art

- [sorah-debuild](https://github.com/sorah/config/blob/master/bin/sorah-debuild), [sorah-debuild-auto](https://github.com/sorah/config/blob/master/bin/sorah-debuild-auto) and [sorah-debuild-codebuild](https://github.com/sorah/config/blob/master/bin/sorah-debuild-codebuild), the local build scripts this replaces
- [sorah-deb-release](https://github.com/sorah/config/blob/master/bin/sorah-deb-release), which `bin/publish` is derived from
- [sts-cat](https://github.com/sorah/sts-cat), for cross-repository tokens

## License

MIT License. See [LICENSE](./LICENSE).
