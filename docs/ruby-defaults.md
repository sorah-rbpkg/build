# ruby-defaults

`ruby_debian_dev.rb` of [sorah-rbpkg/ruby-defaults](https://github.com/sorah-rbpkg/ruby-defaults) lists the Ruby interpreters a distro supports. `ruby-all-dev` depends on `rubyX.Y:any, rubyX.Y-dev` for each of them, and gem2deb builds extensions for each and adds `libruby (<< ...)` from them to every package it builds. So the list must name only Rubies that can be installed on the distro, and it differs per distro.

## Series branch

`master-N.M`, `master` or `next-N.M` lists every Ruby the series supports, newest first, with N.M the newest:

```ruby
has_support_for 'ruby4.0' do
  {
    version:             '4.0',
    binary:              '/usr/bin/ruby4.0',
    api_version:         '4.0.0',
    shared_library:      'libruby4.0',
    min_ruby_version:    '1:4.0~0',
    ruby_upper_bound:    '1:4.1~',
  }
end
```

`ruby_upper_bound` is the Ruby after this one, as Debian does: `1:4.1~` for ruby4.0, `1:4.0~` for ruby3.4. gem2deb's `dh_ruby_fixdepends` adds `libruby (<< <the highest one>)`, which our `libruby 1:N.M+0nkmiK` has to satisfy, so its own version (`1:4.0~`) leaves those packages uninstallable.

## dist branches

Each `dist/N.M/<distro>` branch carries one commit, `ruby_debian_dev.rb: list the Rubies <distro> has`, on top of what the series branch lists:

- Drop each Ruby that neither the distro's archive nor our `<distro>` suite has.
- Add the Ruby the distro ships, when the series does not list it.

| distro   | ships   | left out                                                         |
|----------|---------|------------------------------------------------------------------|
| focal    | ruby2.7 |                                                                  |
| bullseye | ruby2.7 |                                                                  |
| jammy    | ruby3.0 |                                                                  |
| noble    | ruby3.2 | ruby3.1 and older                                                |
| resolute | ruby3.3 | ruby3.2 and older                                                |
| bookworm | ruby3.1 | ruby3.1 and older: its ruby-sdbm needs `libruby (<< 1:3.2~)`, which ours is not |
| trixie   | ruby3.3 | ruby3.2 and older                                                |

Each release merges the series commit into the dist branch, so the commit carries over to every release after. A distro the series list already fits, like jammy for 3.3, needs no commit, and its first release creates its dist branch at the series commit.

The commit is made before the series' first release on the distro, or on top of its last release, merged with the series branch first:

```sh
git checkout -b dist/4.0/jammy debian/1%4.0+0nkmi1_jammy  # or the existing dist/4.0/jammy
git merge --no-ff -m "Merge branch 'master' into dist/4.0/jammy" master
# edit ruby_debian_dev.rb, then commit
```

Merging first keeps the release's own merge trivial. A series change to an entry the dist branch dropped otherwise conflicts there, failing that distro's build.

## Changes

- A new series (`debian/newruby N.M`) starts from the previous series' list. Make its dist branches before its first release, with the same commit as the previous series' dist branch of each distro.
- A new distro for a series needs its row in the table above and a dist branch, unless the series list already fits it.
- A Ruby added to or dropped from a distro's suite changes what fits there. Change the dist branches of every series building that distro, and release them.
- Each change needs a new version of the series, as every distro's tag already exists.

## Checking

Every series' ruby-defaults goes into the same suite, so a distro gets `libruby` and `ruby` of the newest series it has. A list fits when its Rubies install next to them, in a stock image of the distro with the apt repository added (and `<distro>-proposed` for a proposed series):

```sh
# in ruby-defaults, at the dist branch merged with the series branch
sh debian/ruby-all-dev-depends | sed 's/^ruby-all-dev:Depends=//; s/:any//g; s/,//g' > tmp/deps
# in the stock image, with the apt repository added as smoke/lib.sh does
apt-get install -s ruby ruby-dev $(cat deps)
```
