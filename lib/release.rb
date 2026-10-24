# Shared by bin/publish and bin/promote, which load aws-sdk-core and httpx through bundler/inline first.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'aws-sdk-core'
require 'httpx'

ROOT = File.expand_path('..', __dir__)
BUILD_REPOSITORY = 'sorah-rbpkg/build'
OIDC_ISSUER = 'https://token.actions.githubusercontent.com'
APTLY_REPO_PREFIX = 'sorah-ruby'
APTLY_ENDPOINT = 's3:sorah-ruby:'
APTLY_GPG_KEY = '805E57E2327EE86EB8180E0669CEB9D53F0F56A8'
APT_URL = 'https://cache.ruby-lang.org/lab/sorah/deb'
STSCAT_CONFIG = File.expand_path('~/.nkmi-deb-release.json')
# Must stay in sync with .github/scripts/draft-release.js.
RESIGNED_MARKER = '<!-- resigned-by:'
# gh attestation verify takes a few seconds per file, mostly waiting on the network.
ATTESTATION_JOBS = 8
# gh release download already fetches the assets of one release in parallel.
DOWNLOAD_JOBS = 4

def signer_workflow(name) = "#{BUILD_REPOSITORY}/.github/workflows/#{name}"

def index_urls(distro)
  files = %w[InRelease Release Release.gpg]
  %w[binary-amd64 binary-arm64].each { |dir| files.push(*%w[Packages Packages.gz Packages.bz2 Release].map { "main/#{dir}/#{it}" }) }
  files.push(*%w[Sources Sources.gz Sources.bz2 Release].map { "main/source/#{it}" })
  files.map { "#{APT_URL}/dists/#{distro}/#{it}" }
end

# Leaves out the environment hash, which carries GH_TOKEN.
def display_cmd(cmd) = cmd.grep_v(Hash).join(' ')

def run(*cmd, **opts)
  dir = "#{Pathname(opts[:chdir]).relative_path_from(Dir.pwd)} " if opts[:chdir]
  puts "  #{dir}$ #{display_cmd(cmd)}"
  system(*cmd, exception: true, **opts)
end

def capture(*cmd, **opts)
  out, status = Open3.capture2(*cmd, **opts)
  raise "#{display_cmd(cmd)} failed" unless status.success?
  out
end

# Runs the block for each item on that many threads, raising the first error once all have stopped.
def each_parallel(items, jobs)
  queue = Queue.new
  items.each { queue << it }
  queue.close
  workers = Array.new(jobs) do
    Thread.new do
      Thread.current.report_on_exception = false
      while (item = queue.pop)
        yield item
      end
    end
  end
  workers.each(&:join)
end

def parse_debian_metafile(str)
  raw = str[/-----BEGIN PGP SIGNED MESSAGE-----\n.+?\n\n(.+)-----BEGIN PGP SIGNATURE-----/m, 1] || str
  raw.each_line(chomp: true).reject(&:empty?).slice_before { it[0] != ' ' }.to_h do |lines|
    key, val = lines.first.split(':', 2)
    [key, [val&.strip, *lines.drop(1).map(&:strip)].reject { it.nil? || it.empty? }]
  end
end

def release_body(changes_by_arch:, dsc:, attestations: nil, resigned_by: nil)
  body = []
  body.push(attestations, '') if attestations
  body.push('### Changes', '')
  changes_by_arch.sort.each do |arch, content|
    body.push("#### #{arch}", '', '```', content.chomp, '```', '')
  end
  body.push('### dsc', '', '```', dsc.chomp, '```')
  body.push('', "#{RESIGNED_MARKER} #{resigned_by} -->") if resigned_by
  body.join("\n")
end

# The section draft-release.js writes, carried over when the body is rewritten.
# Older drafts carry it at the end rather than the top.
def attestation_section(body) = body[/^### Attestations\n.*?(?=\n\n###|\n\n<!--|\z)/m]&.rstrip

def github_token
  return ENV['GH_TOKEN'] if ENV['GH_TOKEN']

  config = JSON.parse(File.read(STSCAT_CONFIG))
  id_token = Aws::STS::Client.new.get_web_identity_token(
    audience: [config.fetch('stscat_audience')],
    signing_algorithm: 'ES384',
    duration_seconds: 300,
  ).web_identity_token
  resp = HTTPX.post(
    "#{config.fetch('stscat_url')}/token",
    json: {scope: 'sorah-rbpkg', identity: config.fetch('stscat_identity', 'release')},
    headers: {'authorization' => "Bearer #{id_token}", 'user-agent' => 'sorah-rbpkg-build-publish'},
  )
  resp.raise_for_status
  resp.json.fetch('token')
end

def gpg_fingerprint
  out = capture('gpg', '--with-colons', '--list-secret-keys', *ENV['GPGUSER'])
  # A capital S marks a key that can still sign, which leaves out revoked and expired ones.
  out[/^sec:(?:[^:]*:){10}[^:]*S[^:]*:.*\n(?:(?!sec:).*\n)*?fpr:+(\h{40}):/, 1] or raise 'no usable GPG signing key found'
end

# Primary key fingerprints that made a good signature, from gpg's VALIDSIG status lines.
def valid_signers(status_output)
  status_output.scan(/^\[GNUPG:\] VALIDSIG .*?(\h{40})\s*$/).flatten
end

# GitHub replaces characters such as "~" in release asset names with ".".
def asset_name(file) = File.basename(file).gsub(/[^A-Za-z0-9._+-]/, '.')

# Gives downloaded assets back the names that the .changes and .dsc files refer to them by.
def restore_asset_names(dir)
  names = Dir[File.join(dir, '*.{changes,dsc}')].flat_map do |meta|
    parse_debian_metafile(File.read(meta)).fetch('Files').map { it.split.last }
  end
  names.uniq.each do |name|
    downloaded = File.join(dir, asset_name(name))
    File.rename(downloaded, File.join(dir, name)) if name != asset_name(name) && File.exist?(downloaded)
  end
end

# The series build files, each naming a source package, the repository it comes from and its dist branches.
SERIES = Dir[File.join(ROOT, 'gen', 'builds', '*.json')].sort.map { JSON.parse(File.read(it)) }

# cache.ruby-lang.org keeps serving the previous index until it is purged.
def purge(urls)
  headers = {'x-purge-token' => ENV['RB_PURGE_TOKEN'], 'user-agent' => 'sorah-rbpkg-build-publish'}
  urls.zip(HTTPX.request('PURGE', urls, headers:)).each do |url, resp|
    raise "PURGE #{url}: #{resp.error.message}" if resp.error
    raise "PURGE #{url}: HTTP #{resp.status}" unless (200..299).cover?(resp.status)
    puts "  purged #{url}"
  end
end

# Pins the newest released version of each series and distro in versions.json of sorah-rbpkg/dockerfiles.
class DockerfilesRelay
  BRANCH = 'master'
  # The images install rubyN.M packages, which come from here.
  REPOSITORY = 'sorah-rbpkg/ruby'

  def initialize(dir:, token:, dry_run:)
    @dir = dir
    @dry_run = dry_run
    @env = {'GH_TOKEN' => token}
    @path = File.join(dir, 'versions.json')
  end

  # Runs before anything is published, so a checkout that cannot take the commits fails early.
  def check
    abort "#{@dir} has no versions.json; pass --dockerfiles-dir" unless File.exist?(@path)
    abort "#{@dir} has uncommitted changes" unless git('status', '--porcelain', '--untracked-files=no').empty?
    abort "#{@dir} is not on #{BRANCH}" unless git('branch', '--show-current').strip == BRANCH
    run('git', 'fetch', '-q', 'origin', BRANCH, chdir: @dir)
    abort "#{@dir}: #{BRANCH} is not at origin/#{BRANCH}" unless git('rev-parse', BRANCH) == git('rev-parse', "origin/#{BRANCH}")
  end

  def sync
    puts '=> relaying to dockerfiles'
    versions = JSON.parse(File.read(@path))
    tracked = versions.flat_map { |series, distros| distros.keys.map { [series, it] } } | built_pairs
    released = released_versions
    changes = tracked.sort.filter_map do |series, distro|
      version = released[[series, distro]] or next
      current = versions.dig(series, distro)
      [series, distro, version] if current.nil? || newer?(version, current)
    end
    if changes.empty?
      puts ' * versions.json is up to date'
      return
    end

    changes.group_by { |series, distro, version| [series, version.delete_suffix("~#{distro}")] }.each do |(series, version), entries|
      subject = "roll ruby#{series} #{version}"
      distros = entries.map { it[1] }
      if @dry_run
        puts " * would commit #{subject} for #{distros.join(', ')}"
        next
      end
      entries.each { |_, distro, deb_version| (versions[series] ||= {})[distro] = deb_version }
      File.write(@path, "#{JSON.pretty_generate(versions.sort.to_h { |s, ds| [s, ds.sort.to_h] })}\n")
      run('git', 'commit', '-q', '-m', subject, '-m', "Released for #{distros.join(', ')}.", '--', 'versions.json', chdir: @dir)
    end
    # Without --force, so a concurrent push fails rather than being overwritten.
    run('git', 'push', 'origin', BRANCH, chdir: @dir) unless @dry_run
  end

  private

  def git(*args) = capture('git', *args, chdir: @dir)

  def built_pairs
    SERIES.select { it.fetch('repository') == REPOSITORY }.flat_map do |series|
      series.fetch('distros').map { [series.fetch('source').delete_prefix('ruby'), it] }
    end
  end

  # Keyed by [series, distro], from the debian/<version>_<distro> tags of published releases.
  def released_versions
    tags = JSON.parse(capture(@env, 'gh', 'release', 'list', '--repo', REPOSITORY, '--limit', '1000', '--json', 'tagName,isDraft'))
      .reject { it.fetch('isDraft') }.map { it.fetch('tagName') }.grep(%r{\Adebian/})
    versions = tags.map { it.delete_prefix('debian/').gsub('.#', '.').tr('_%', '~:') }
    pairs = versions.filter_map do |version|
      series = version[/\A(\d+\.\d+)\./, 1]
      distro = version[/~([a-z]+)\z/, 1]
      [[series, distro], version] if series && distro
    end
    pairs.group_by(&:first).transform_values { |vs| vs.map(&:last).reduce { |a, b| newer?(b, a) ? b : a } }
  end

  def newer?(a, b) = system('dpkg', '--compare-versions', a, 'gt', b)
end
