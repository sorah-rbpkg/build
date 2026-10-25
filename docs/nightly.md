# Nightly packages

[`nightly.yml`](../.github/workflows/nightly.yml) builds every `rubyN.M` series from the [snapshot](https://cache.ruby-lang.org/pub/ruby/snapshot/) of its `ruby_N_M` branch each Monday, or of `master` for a proposed series, whose branch is not cut yet, on the standard runners. Nothing is tagged, released or added to the apt repository: the packages stay as artifacts of the run, `nightly-<series>-<distro>-<arch>`, for 90 days.

- The version is `<X.Y.Z>+git<YYYYMMDD>.g<commit>-0nkmi0~<distro>`, from the snapshot's `version.h` and `revision.h`. It sorts after the release the branch is at and before the next one, and its `0nkmi0` below a release's `0nkmi1`. Before `X.Y.Z` is released, with patchlevel `-1`, the version follows the pre-release the head of the series' `master` branch packages, as `4.1.0~preview1+git<YYYYMMDD>.g<commit>`, which sorts between `preview1` and the next pre-release; without one it is `<X.Y.Z>~git...`.
- The snapshot is the orig tarball as is, checked against the sha256 in its `snapshot-ruby_N_M.json`. A proposed series smokes with its `<distro>-proposed` suite, for its ruby-defaults. Each distro builds the `debian/` of its `dist/N.M/<distro>` branch, or of the series `commit` before its first release, merged with the signed head of the series' `master` branch, without the patches the snapshot already has. A packaging fix on that branch reaches the next nightly without a release or `bin/roll`.
- Distros that pass smoke on every arch are rolled into [`nightly.json`](https://github.com/sorah-rbpkg/dockerfiles/blob/master/nightly.json) of sorah-rbpkg/dockerfiles, which builds the `N.M.next` images from the artifacts.
- A series whose snapshot is still at the revision `nightly.json` has for every distro is skipped.

`bin/plan-nightly` shows locally what a run would build. Running `nightly` by hand takes a `series`, `force` to build an unchanged snapshot, and `roll` unchecked to leave sorah-rbpkg/dockerfiles alone.

## nightly.json

The roll job commits one entry per series and distro to sorah-rbpkg/dockerfiles, keeping the entries of distros that failed this time:

```jsonc
{
  "3.4": {
    "noble": {
      "version": "3.4.12+git20261023.g366f5fdc00-0nkmi0~noble",
      "revision": "366f5fdc00cbd2e7997e03b6654d10163ff19bad",  // full commit of the snapshot
      "run_id": 40085790150,                                   // the nightly run holding the artifacts
      "artifacts": { "amd64": "nightly-ruby3.4-noble-amd64", "arm64": "nightly-ruby3.4-noble-arm64" }
    }
  }
}
```

The commit is made through the GitHub API with a token from sts-cat, so GitHub signs it, and only fast-forwards `master`. sorah-rbpkg/dockerfiles downloads the artifacts with its own sts-cat token and verifies their attestations from `nightly.yml` before installing them.

## Failures

- A patch that neither applies nor is already in the snapshot fails that distro's build. Fix it on the series' `master` branch, and run `nightly` by hand with `force` to pick it up before the snapshot moves.
- A `dist/N.M/<distro>` branch whose own `debian/` changes conflict with the series' `master` branch fails that distro's build at the merge.
- A distro that fails to build or smoke on any arch keeps last week's entry in `nightly.json`, and its images stay as they were.
- The artifacts expire after 90 days. A series whose branch does not move for that long is skipped every week, and its images fail to rebuild once they expire; run `nightly` by hand with `force` to renew them.
