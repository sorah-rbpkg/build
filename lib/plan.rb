# Shared by bin/plan and bin/plan-nightly.
require 'json'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
BUILD_REPOSITORY = ENV.fetch('GITHUB_REPOSITORY', 'sorah-rbpkg/build')
COMMITTERS_KEYRING = File.join(ROOT, 'keys', 'committers.asc')
# Any other distro is taken to be an Ubuntu release.
DEBIAN_CODENAMES = %w[stretch buster bullseye bookworm trixie forky duke]

Series = Data.define(:file, :source, :repository, :master, :commit, :dist, :distros, :archs, :smoke, :large_runner, :test) do
  def self.load(path)
    config = JSON.parse(File.read(path))
    new(
      file: path,
      source: config.fetch('source'),
      repository: config.fetch('repository'),
      master: config.fetch('master'),
      commit: config.fetch('commit'),
      dist: config.fetch('dist'),
      distros: config.fetch('distros'),
      archs: config.fetch('archs'),
      smoke: config.fetch('smoke'),
      large_runner: config.fetch('large_runner'),
      test: config.fetch('test'),
    )
  end

  def url = "https://github.com/#{repository}.git"
  # Unique across series, unlike source: ruby-defaults has one series per default Ruby.
  def id = File.basename(file, '.json')

  # dockerfiles/<id>/ holds overrides for a single series.
  def dockerfile(distro)
    ["dockerfiles/#{id}/Dockerfile.#{distro}", "dockerfiles/Dockerfile.#{distro}"]
      .find { File.exist?(File.join(ROOT, it)) } or raise "#{file}: no dockerfiles/Dockerfile.#{distro}"
  end
end

def git(*args, dir: nil)
  cmd = dir ? ['git', '-C', dir, *args] : ['git', *args]
  out, status = Open3.capture2(*cmd)
  raise "#{cmd.join(' ')} failed" unless status.success?
  out
end

def git?(*args, dir:)
  system('git', '-C', dir, *args, out: File::NULL, err: File::NULL)
end

# A bare clone of the series' repository under tmp/, with the master branch fetched as refs/remotes/origin/<master>.
def fetch_master(series)
  dir = File.join(ROOT, 'tmp', 'plan', series.repository.tr('/', '_'))
  git('init', '-q', '--bare', dir) unless File.directory?(dir)
  git('fetch', '-q', '--filter=blob:none', '--no-tags', series.url, "+refs/heads/#{series.master}:refs/remotes/origin/#{series.master}", dir:)
  dir
end

# Only commits and upstream tags signed by a key in keys/committers.asc may be built.
# kind is "commit" or "tag", for git verify-commit or verify-tag.
def verify_signature(kind, ref, dir:)
  Dir.mktmpdir('plan-gnupg') do |gnupghome|
    env = {'GNUPGHOME' => gnupghome}
    _, status = Open3.capture2e(env, 'gpg', '--batch', '--import', COMMITTERS_KEYRING)
    raise "cannot import #{COMMITTERS_KEYRING}" unless status.success?
    trusted = Open3.capture2(env, 'gpg', '--batch', '--with-colons', '--list-keys').first.scan(/^fpr:+(\h{40}):/).flatten

    _, raw, _ = Open3.capture3(env, 'git', '-C', dir, "verify-#{kind}", '--raw', ref)
    signer = raw[/^\[GNUPG:\] VALIDSIG .*?(\h{40})\s*$/, 1]
    raise "#{ref} is not signed by a key in #{File.basename(COMMITTERS_KEYRING)}" unless signer && trusted.include?(signer)
  end
end

# The build job's runs-on. The large ones are org-paid, 64 cores each, in the runner group that admits public repositories.
def runner_for(arch, large:)
  if large
    {group: 'build', labels: arch == 'arm64' ? 'ubuntu-24.04-arm64-large' : 'ubuntu-24.04-large'}
  else
    arch == 'arm64' ? 'ubuntu-24.04-arm' : 'ubuntu-24.04'
  end
end

# The stock image the smoke test installs the packages on.
def image_for(distro)
  "#{DEBIAN_CODENAMES.include?(distro) ? 'debian' : 'ubuntu'}:#{distro}"
end
