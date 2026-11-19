# Release tools

The scripts under [`bin/`](../bin) that take a release from ruby-lang.org to the apt repository. The [README](../README.md#releasing-a-new-version) lists the commands in the order they run.

## bin/import

`bin/import` downloads each release from ruby-lang.org and checks its sha256 against [ruby/www.ruby-lang.org](https://github.com/ruby/www.ruby-lang.org/blob/master/_data/releases.yml). For a release not announced yet, `--pr NUMBER` (repeatable) takes the checksums from pull requests to that repository, pinned to each head commit and refused from forks, and the tarball comes from the `pub/tmp/` draft until it is published. The checksum it trusted is written to `checksums/ruby-<version>.json`, which `bin/roll` commits with the series and the build checks the orig against; `bin/import --checksum-only [--pr NUMBER] VERSION` writes only that file, for a version imported without one. It runs `gbp import-orig` onto `upstream-N.M` with a signed `upstream/<version>` tag and pristine-tar data, and merges it into `master` or `master-N.M`, whichever holds the series, or into the branch `--branch N.M=BRANCH` names. It then commits the changelog entry as `releng <version>-0nkmi1` and checks the orig the build would generate with `bin/verify-orig`. Each branch it touches must match `origin`, unless `--ahead BRANCH=SHA` acknowledges that branch's unpushed commits up to exactly that commit. `bin/import --push` shows the new commits on each of those branches and `pristine-tar`, then pushes them and the tags in one atomic push once you confirm, or without asking with `--yes`.

`bin/import --draft VERSION` imports the `pub/tmp/` draft of a release instead, onto `draft/<branch>` and `draft/upstream-N.M`, branched from `origin`, with the draft's checksum and no pristine-tar data, so a draft that upstream re-cuts can be thrown away. `--push --draft` pushes only those two branches and the tag, and `bin/roll draft/<branch>` builds them. `bin/import --discard VERSION` deletes them and the tag here and on `origin`, refusing a release already finalized. Once the release is published, `bin/import --finalize VERSION` checks the published tarball against `checksums/ruby-<version>.json` and the orig against it, commits its pristine-tar data, and in one atomic push fast-forwards the real branches to the draft ones, pushes `pristine-tar` and deletes the draft branches. It refuses, changing nothing, when the real branch has moved past the draft, which then needs rebasing onto it.

## bin/releng-watch

`bin/releng-watch VERSION...` runs `bin/import --draft`, `bin/check-patches`, `bin/roll`, `--discard` and `--finalize` as each release moves upstream, and lists what needs a person. [releng-watch.md](./releng-watch.md) describes it.

## bin/check-patches

`bin/check-patches REV...` applies `debian/patches/series` at each revision of a local checkout, `../ruby` by default, as `dpkg-source` does before a build: in order and without fuzz. It lists each patch that needs fuzz, is already upstream, or does not apply, and exits 1 if there is any. `bin/import` runs it on each branch it imports onto and `bin/roll` on each commit it rolls; both only warn, as the fix is a follow-up `gbp pq` commit. Nightly runs give the same warning earlier, as soon as a branch snapshot has a patch upstream or needs it refreshed.

## bin/roll

`bin/roll` reads the source package from `debian/changelog` at each revision to find its series, sets `commit` in `builds/<series>.jsonnet`, and runs `bin/generate`. It checks every series with `bin/plan` before committing any, then commits each as `roll <series> <version>`, together with `checksums/ruby-<upstream version>.json` unless the package is native. A `draft/<branch>` revision rolls the series of `<branch>`. A series in [test mode](./test-mode.md) leaves it when the revision is a new release. It first makes sure your checkout of sorah-rbpkg/ruby, `../ruby` by default, has pushed each branch and its `upstream/<version>` tag.

## bin/publish

`bin/publish` takes the drafts through four steps, skipping any that is already done, so a failed run can be repeated:

1. Verifies the gitsign signature of the tag against `_distro.yml` on `main`, that the tag is on the dist branch of a series building that source package, the build attestation of every asset, and the checksums in the `.changes` and `.dsc`. Every draft is verified, the signatures and attestations of all of them in parallel, before any is re-signed.
2. Re-signs the tag with `git tag -s`, and the `.changes`, `.dsc` and `.buildinfo` with `sorah-debsign`, then replaces them on the draft.
3. Once every draft is re-signed, adds them all with `aptly repo add`, runs `aptly publish update` once per suite, purges the distros' index from cache.ruby-lang.org with `RB_PURGE_TOKEN`, and only then publishes the releases, which makes them immutable.
4. Commits the newest released version of each series and distro to `versions.json` in your checkout of [sorah-rbpkg/dockerfiles](https://github.com/sorah-rbpkg/dockerfiles), `../dockerfiles` by default, as `roll <source> <version>`, and pushes it, which rebuilds those images. It checks before step 3 that the checkout is clean and at `origin/master`, and never moves a version back.

The suite is the `Suite:` line the build wrote at the top of the draft: `<distro>`, or `<distro>-proposed` for a proposed series, whose release stays a pre-release. A release without the line goes into its distro. Pre-releases are never committed to `versions.json`.

## bin/promote

`bin/promote` takes published pre-releases from `<distro>-proposed` into `<distro>`. It copies exactly the packages the release's `.changes` list with `aptly repo copy`, runs `aptly publish update` for each distro, and purges their index. It then marks each release as released and rewrites its `Suite:` line, leaving the assets as they are, and updates `versions.json` as `bin/publish` does. It refuses a draft, a release that is not a pre-release, and one whose suite is not `-proposed`. It shares `bin/publish`'s lock.

Both get their GitHub token from `GH_TOKEN`, or from sts-cat through the `DebReleaser` role:

```jsonc
// ~/.nkmi-deb-release.json
{
  "stscat_url": "https://sts-cat.example.com",
  "stscat_audience": "https://sts-cat.nkmi.me"
}
```
