# Setup

Done once for sorah-rbpkg, and kept for reference.

## 1. Configure this repository

Create the `release` environment with a required reviewer and the secret `STS_CAT_ENDPOINT`, and the `nightly` environment, limited to `main`, with the same secret.

## 2. Trust the jobs that need other repositories

The release job, and the roll job of `nightly.yml`, obtain their tokens from [sts-cat](https://github.com/sorah/sts-cat), through org-level trust policies in [sorah-rbpkg/.github](https://github.com/sorah-rbpkg/.github/tree/main/.github/sts-cat):

- [`build.sts.toml`](https://github.com/sorah-rbpkg/.github/blob/main/.github/sts-cat/build.sts.toml): the release job of `_distro.yml` on `main`, in the `release` environment, writes the source repositories.
- [`nightly.sts.toml`](https://github.com/sorah-rbpkg/.github/blob/main/.github/sts-cat/nightly.sts.toml): the roll job of `nightly.yml` on `main`, in the `nightly` environment, writes sorah-rbpkg/dockerfiles.
- [`dockerfiles-nightly.sts.toml`](https://github.com/sorah-rbpkg/.github/blob/main/.github/sts-cat/dockerfiles-nightly.sts.toml): sorah-rbpkg/dockerfiles' build on `master` reads the artifacts of this repository. It needs `STS_CAT_ENDPOINT` as a repository secret there.

## 3. Prepare the local tools

```
mise install
hk install
```

`hk check --all` runs the same checks as CI. [`bin/publish`](./tools.md#binpublish) additionally needs `gpg`, [`sorah-debsign`](https://github.com/sorah/config/blob/master/bin/sorah-debsign) on `PATH`, and an `aptly` configured with the `sorah-ruby-<distro>` repositories and the `s3:sorah-ruby:` endpoint, and a checkout of sorah-rbpkg/dockerfiles you can push to `master`, `../dockerfiles` by default.
