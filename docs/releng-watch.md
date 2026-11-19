# bin/releng-watch

`bin/releng-watch` follows ruby releases from their upstream drafts to the release jobs waiting for approval, so the packages build while upstream is still testing them. It drives [`bin/import`](./tools.md#binimport), [`bin/check-patches`](./tools.md#bincheck-patches) and [`bin/roll`](./tools.md#binroll), and lists whatever needs a person under ACTION REQUIRED.

## How a ruby release reaches us

1. [ruby/actions `draft-release.yml`](https://github.com/ruby/actions/actions/workflows/draft-release.yml) uploads `pub/tmp/ruby-<version>-draft.tar.gz` and `pub/tmp/ruby-info-<version>-draft.yml`, the `releases.yml` entry with its sha256. Upstream may re-cut a draft, under the same names.
2. [ruby/ruby `publish.yml`](https://github.com/ruby/ruby/actions/workflows/publish.yml) moves the draft into `pub/ruby/N.M/` as it is, and opens matzbot's pull request to ruby/www.ruby-lang.org.
3. Merging that pull request adds the release to `master`'s `_data/releases.yml`, which announces it.

The monitor builds at step 1, finalizes at step 2, and asks for the approval after step 3. The release job releases nothing before step 3, as it checks the orig against `master`'s `releases.yml` and that the series commit is on its real branch ([architecture.md](./architecture.md)).

## Prerequisites

- A signing key unlocked in gpg-agent, for the `upstream/<version>` tags, the roll commits and pristine-tar. The monitor checks it on every poll without prompting, so an expiring agent defers the steps that sign until you unlock it again.
- A clean checkout of sorah-rbpkg/ruby, `../ruby` by default, whose branches have nothing unpushed.
- This repository on `main`, clean, with nothing unpushed.
- `gh auth login`, for the build runs, the pull requests and rejecting approvals.

## Running it

```
bin/releng-watch 4.0.11 3.4.14             # watch one version per series, pushing as it goes
bin/releng-watch --no-push 4.0.11          # only do what stays local; print the pushes
bin/releng-watch --status                  # in another terminal: the last poll's list
bin/releng-watch --reset 4.0.11            # forget a version stopped for a person to resolve
```

It runs in the foreground; Ctrl-C stops it and running it again picks up where it was, from `tmp/releng-watch/` or, if that is gone, from the refs on `origin` and `checksums/`. Only one runs at a time. Pressing Enter polls at once.

Polls are 15 seconds to 10 minutes apart: relaxed while nothing moves, every 20 seconds while a draft is uploading or publish is running, after the monitor acted, and while ACTION REQUIRED lists something for you, and every minute once a build nears its usual length.

## What it pushes

Unless `--no-push`:

- `bin/import --push --draft`: `draft/<branch>`, `draft/upstream-N.M` and the `upstream/<version>` tag of sorah-rbpkg/ruby.
- `bin/roll draft/<branch>` and `git push origin main` here, which starts the build. It rebases onto `origin/main` once if `main` moved.
- `bin/import --discard`: deletes those draft refs on a re-cut, and rejects the release approvals still pending for the discarded build.
- `bin/import --finalize`: fast-forwards `<branch>` and `upstream-N.M` to the draft branches, pushes `pristine-tar`, and deletes the draft branches.

Nothing is force-pushed, and every push of sorah-rbpkg/ruby is atomic.

## A release day

Illustrative output, abridged:

```
$ bin/releng-watch 4.0.11 3.4.14
[22:31:05] 4.0.11: waiting_draft, next poll in 600s
[22:41:12] 4.0.11: import_draft
  $ bin/import --draft --source-dir ../ruby 4.0.11
  │ => ruby4.0 4.0.11 on draft/master
  │   checksums/ruby-4.0.11.json: 9a3f… from draft
  $ bin/check-patches --source-dir ../ruby draft/master
  │ draft/master: 12 of 12 patches apply
[22:41:40] 4.0.11: drafted
[22:41:41] 3.4.14: import_draft
  $ bin/check-patches --source-dir ../ruby draft/master-3.4
  │ draft/master-3.4: 0006-fix-mkmf.patch: does not apply
[22:42:02] 3.4.14: paused_patches
4.0.11: drafted (build: -)
3.4.14: paused_patches (build: -)
── ACTION REQUIRED (1) ─────────────────────────────────────────────────
[3.4.14 ] debian/patches fails on draft/master-3.4: cd ../ruby && git checkout draft/master-3.4 && gbp pq import --force --time-machine=5 && gbp pq rebase && gbp pq export && git commit -a
────────────────────────────────────────────────────────────────────────
[22:42:22] 4.0.11: push_and_roll
  $ bin/import --push --draft --yes 4.0.11
  $ bin/roll --source-dir ../ruby draft/master
  │ roll ruby4.0 4.0.11-0nkmi1
[22:42:30] 4.0.11: building
```

After you commit the refreshed patch on `draft/master-3.4`, the monitor checks it, pushes it and rolls it on its own:

```
[22:51:10] 3.4.14: check_patches
[22:51:12] 3.4.14: drafted
[22:51:32] 3.4.14: push_and_roll
[22:51:41] 3.4.14: building
```

Upstream re-cuts 4.0.11's draft. The monitor throws its build away and starts over:

```
[23:05:40] 4.0.11: discard (the draft was re-cut: sha256 c01d…, not 9a3f…)
  $ bin/import --discard --yes 4.0.11
[23:05:44] 4.0.11: rejected the pending release of https://github.com/sorah-rbpkg/build/actions/runs/44500000001
[23:06:04] 4.0.11: import_draft
[23:06:30] 4.0.11: push_and_roll
```

`publish.yml` moves the drafts into `pub/ruby/`, and the monitor finalizes each:

```
[23:36:01] 4.0.11: finalize
  $ bin/import --finalize --yes 4.0.11
  │   https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.11.tar.gz matches checksums/ruby-4.0.11.json
  │ Finalized 4.0.11
[23:36:20] 4.0.11: building -> finalized
[23:37:02] 3.4.14: building -> finalized
```

Builds finish while the pull requests wait. Distros ready early show as progress, never as an action:

```
4.0.11: finalized (build: 5 awaiting_approval)
3.4.14: finalized (build: 3 awaiting_approval, 2 building)
no action required
```

The pull requests are merged, and once every distro of both versions waits, a single entry asks for every approval:

```
[00:41:15] 4.0.11: finalized -> announced
[00:41:15] 3.4.14: finalized -> announced
── ACTION REQUIRED (1) ─────────────────────────────────────────────────
[all    ] approve every release job at once: https://github.com/sorah-rbpkg/build/actions/runs/44500000003 https://github.com/sorah-rbpkg/build/actions/runs/44500000004
────────────────────────────────────────────────────────────────────────
...
every distro is released; run bin/publish
```

## ACTION REQUIRED

| Entry | What to do |
|---|---|
| `unlock your signing key` | `echo \| gpg --clearsign >/dev/null`; signing steps were deferred and run on the next poll |
| `commit or stash in ../ruby` | Clean the checkout `bin/import` works in |
| `finish or abort the rebase or merge in ../ruby` | Finish or abort it |
| `gbp pq export, or switch back from patch-queue/<branch>` | Finish the `gbp pq` session |
| `push or reset <branch> in ../ruby: it has commits origin lacks` | Push them through the usual route, or reset the branch to `origin` |
| `reset draft/<branch> in ../ruby to origin` | The local draft branch diverged from `origin`'s; reset it as printed |
| `switch … to main` / `commit or discard the changes in builds/ gen/ checksums/` / `push or drop your unpushed commits on main` | Put this repository back on a clean `main` that matches `origin` |
| `debian/patches fails on draft/<branch>` | Refresh or drop the patches with `gbp pq` as printed, and commit on the draft branch. The monitor continues when the branch moves |
| `build of <series> <distro> failed (<jobs>)` | Re-run it with `gh run rerun <id> --failed`, or commit a fix on the draft branch, which the monitor checks, pushes and rolls |
| `<branch> on origin moved past draft/<branch>` | Rebase the draft branch onto it and force-push it as printed. The monitor rolls the rebased branch and finalizes after that |
| `reject the <series> release jobs of <run> yourself` | A discarded build shares its run with another series, which a rejection would also hit. Reject that series' jobs by hand, or leave them: the release job refuses a commit that never reached the real branch |
| `push it yourself (--no-push): …` | Run the printed commands |
| `bin/import --finalize … failed 5 times in a row` and the like | Read the log above it; the monitor keeps retrying |
| `stopped: …` | Resolve as printed, then `bin/releng-watch --reset <version>` |
| `approve every release job at once` | Approve the release jobs of every listed run |
| `every distro is released: bin/publish` | Run `bin/publish`; the monitor exits |

## Failures and recovery

The release gate is the backstop. Nothing reaches `dist/*` or `debian/*` unless `master`'s `releases.yml` agrees with both the orig and `checksums/` (or `trusted-checksums.txt` on `main` lists the checksum), and the series commit is on its real branch. So whatever goes wrong before the announcement costs a build, never a wrong release.

| Failure | How it shows | What happens |
|---|---|---|
| The draft tarball and its info disagree, as when caught mid-upload | `bin/import --draft` fails its sha256 check | Discarded and retried each poll; listed after 5 failures in a row |
| `gbp`, `dch` or tag signing fails | `bin/import --draft` fails | Discarded and retried; deferred while signing is locked |
| `debian/patches` does not apply | `bin/check-patches` | `paused_patches` until you commit a fix on the draft branch |
| A build fails | Build tracking | Listed with its failed jobs until a newer attempt or roll builds it |
| Upstream re-cuts the draft | Its sha256 differs from the one built | Discarded, pending approvals rejected, re-imported and rolled with the new checksum |
| Upstream abandons the draft | It is gone from `pub/tmp/` before `pub/ruby/` has it | Discarded; the monitor waits for a new draft |
| The draft push or `git push origin main` is rejected | The push fails | Atomic, so nothing changed; retried, with one rebase onto `origin/main` |
| The real branch moved before finalize | `bin/import --finalize` refuses | Listed with the rebase to do |
| The published tarball differs from the draft built | `bin/import --finalize` refuses | Stopped: `bin/import --discard --yes <version>`, then the usual `bin/import <version>` and `bin/roll` |
| `master`'s `releases.yml` lists another checksum | Comparing it with the one built | Stopped; the release job would refuse it as well |
| A release job was approved too early | The release job fails at "verify against releases.yml" | Re-run it once announced: `gh run rerun <id> --failed` |
| Some distros released, others failed | The release jobs | Re-run the failed ones; existing identical tags are skipped |
| The approval wait expired | The run ends | `gh workflow run build.yml -f series=<series>`, which only builds unreleased distros |
| The monitor restarts or loses `tmp/releng-watch/` | — | Every step checks first, and the state comes back from the refs and `checksums/` |

Its behaviour, including each failure above, is covered by `spec/integration/releng_watch_spec.rb`, which runs it against a throwaway package ([setup.md](./setup.md)).
