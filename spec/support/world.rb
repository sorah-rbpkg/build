require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'time'
require 'tmpdir'
require 'yaml'

# A throwaway sorah-rbpkg/ruby holding a small ruby9.9 package and a copy of this repository's working tree,
# each with a bare origin under github/, plus a signing key and a scenario answering for Releng::FakeExternal.
class World
  ROOT = File.expand_path('../..', __dir__)
  CACHE = 'https://cache.ruby-lang.org/pub'
  RELEASES_URL = 'https://raw.githubusercontent.com/ruby/www.ruby-lang.org/master/_data/releases.yml'
  DRAFT_RUNS = 'repos/ruby/actions/actions/workflows/draft-release.yml/runs?per_page=10'
  PUBLISH_RUNS = 'repos/ruby/ruby/actions/workflows/publish.yml/runs?per_page=5'
  BUILD_RUNS = 'repos/sorah-rbpkg/build/actions/workflows/build.yml/runs?per_page=20'
  NAME = 'Releng Test'
  EMAIL = 'releng-test@example.invalid'

  Result = Data.define(:output, :status) do
    def success? = status.success?
  end

  attr_reader :dir, :env, :scenario

  def self.create
    FileUtils.mkdir_p(File.join(ROOT, 'tmp'))
    new(Dir.mktmpdir('world', File.join(ROOT, 'tmp')))
  end

  def initialize(dir)
    @dir = dir
    @tarballs = {}
    @scenario = {
      'http' => {RELEASES_URL => {'body' => YAML.dump([])}},
      'github' => {
        "GET #{DRAFT_RUNS}" => {'workflow_runs' => []},
        "GET #{PUBLISH_RUNS}" => {'workflow_runs' => []},
        "GET #{BUILD_RUNS}" => {'workflow_runs' => []},
        'GET repos/ruby/www.ruby-lang.org/pulls?head=ruby:releases/9.9.1&state=all' => [],
      },
      'signing' => true,
    }
    @env = {
      'GNUPGHOME' => path('gnupg'),
      'GIT_CONFIG_GLOBAL' => path('gitconfig'),
      'GIT_CONFIG_NOSYSTEM' => '1',
      'RELENG_GITHUB_URL' => "file://#{path('github')}/",
      'RELENG_FAKE_EXTERNAL' => path('scenario.json'),
      'DEBFULLNAME' => NAME,
      'DEBEMAIL' => EMAIL,
      'GH_TOKEN' => nil,
      'GITHUB_TOKEN' => nil,
    }
    save_scenario
    setup_gpg
    setup_ruby
    setup_build
  end

  def cleanup
    system(env, 'gpgconf', '--kill', 'all', out: File::NULL, err: File::NULL)
    FileUtils.rm_rf(dir)
  end

  def path(*parts) = File.join(dir, *parts)
  def ruby_dir = path('ruby')
  def build_dir = path('build')
  def origin(repository) = path('github', "#{repository}.git")

  def sh(*cmd, chdir: dir, input: nil)
    out, status = Open3.capture2e(env, *cmd, chdir:, stdin_data: input.to_s)
    raise "#{cmd.join(' ')} failed in #{chdir}:\n#{out}" unless status.success?
    out
  end

  def run(*cmd, chdir: build_dir, input: nil)
    out, status = Open3.capture2e(env, *cmd, chdir:, stdin_data: input.to_s)
    Result.new(output: out, status:)
  end

  def git(dir, *args) = sh('git', *args, chdir: dir).strip
  def rev(dir, ref) = run('git', 'rev-parse', '--verify', '-q', ref, chdir: dir).then { it.success? ? it.output.strip : nil }

  def bin(name, *args, input: nil) = run(File.join(build_dir, 'bin', name), *args, input:)

  # The upstream release tarball of version, as git archive makes one, so its modes match the build's orig.
  # A greeting other than hello breaks greeting.patch; each cut has different bytes.
  def tarball(version, greeting: 'hello', cut: 1)
    @tarballs[[version, greeting, cut]] ||= begin
      src = path('src', "#{version}-#{greeting}-#{cut}")
      FileUtils.mkdir_p(File.join(src, 'lib'))
      File.write(File.join(src, 'README'), "ruby #{version}, cut #{cut}\n")
      File.write(File.join(src, 'version.h'), "#define RUBY_VERSION \"#{version}\"\n")
      File.write(File.join(src, 'lib', 'greeting.rb'), "def greeting\n  '#{greeting}'\nend\n")
      sh('git', 'init', '-q', chdir: src)
      sh('git', 'add', '.', chdir: src)
      sh('git', 'commit', '-q', '--no-gpg-sign', '-m', version, chdir: src)
      out = path('dist', "#{version}-#{greeting}-#{cut}", "ruby-#{version}.tar.gz")
      FileUtils.mkdir_p(File.dirname(out))
      sh('bash', '-o', 'pipefail', '-c', "git archive --format=tar --prefix ruby-#{version}/ HEAD | gzip -n > #{out}", chdir: src)
      out
    end
  end

  def release_entry(version, tarball)
    series = version[/\A\d+\.\d+/]
    {
      'version' => version,
      'date' => '2026-11-18',
      'url' => {'gz' => "#{CACHE}/ruby/#{series}/ruby-#{version}.tar.gz"},
      'sha256' => {'gz' => Digest::SHA256.file(tarball).hexdigest},
    }
  end

  def update_scenario
    yield scenario
    save_scenario
  end

  # As draft-release.yml uploads it, replacing any earlier draft of the same version.
  def draft(version, tarball: self.tarball(version))
    update_scenario do |s|
      s['http']["#{CACHE}/tmp/ruby-info-#{version}-draft.yml"] = {'body' => YAML.dump([release_entry(version, tarball)])}
      s['http']["#{CACHE}/tmp/ruby-#{version}-draft.tar.gz"] = {'body_file' => tarball}
    end
  end

  # As publish.yml copies the draft into pub/ruby/.
  def publish(version, tarball: self.tarball(version))
    update_scenario do |s|
      s['http']["#{CACHE}/ruby/#{version[/\A\d+\.\d+/]}/ruby-#{version}.tar.gz"] = {'body_file' => tarball}
    end
  end

  # As merging the www.ruby-lang.org pull request adds it to master's releases.yml.
  def announce(version, tarball: self.tarball(version))
    update_scenario do |s|
      entries = YAML.safe_load(s['http'].dig(RELEASES_URL, 'body') || '[]', permitted_classes: [Date])
      s['http'][RELEASES_URL] = {'body' => YAML.dump([release_entry(version, tarball), *entries])}
    end
  end

  # matzbot's pull request to www.ruby-lang.org, whose releases.yml at its head lists version with tarball's sha256.
  def pull_request(version, number:, tarball: self.tarball(version), at: Time.now)
    head = Digest::SHA1.hexdigest("pr#{number}")
    update_scenario do |s|
      s['github']["GET repos/ruby/www.ruby-lang.org/pulls?head=ruby:releases/#{version}&state=all"] = [{
        'number' => number, 'html_url' => "https://github.com/ruby/www.ruby-lang.org/pull/#{number}",
        'head' => {'sha' => head, 'repo' => {'full_name' => 'ruby/www.ruby-lang.org'}},
        'created_at' => at.utc.iso8601, 'updated_at' => at.utc.iso8601,
      }]
      s['http']["https://raw.githubusercontent.com/ruby/www.ruby-lang.org/#{head}/_data/releases.yml"] =
        {'body' => YAML.dump([release_entry(version, tarball)])}
    end
  end

  def job(name, status: 'completed', conclusion: 'success') = {'name' => name, 'status' => status, 'conclusion' => conclusion}

  # The jobs of one distro of a series, all succeeded unless overridden, and the release waiting for approval.
  def distro_jobs(series, distro, release: :waiting, **overrides)
    names = %w[merge build\ (amd64) build\ (arm64) smoke\ (amd64) smoke\ (arm64)]
    jobs = names.map { job("#{series} #{distro} / #{it}", **overrides.fetch(it, {})) }
    jobs << case release
    when :waiting then job("#{series} #{distro} / release", status: 'waiting', conclusion: nil)
    when :success then job("#{series} #{distro} / release")
    when :skipped then job("#{series} #{distro} / release", conclusion: 'skipped')
    end
    jobs.compact
  end

  # Replaces build.yml's runs, newest first as the API lists them, each a Hash with id, jobs and optional
  # attempt, status, conclusion and created_at.
  def build_runs(*runs)
    update_scenario do |s|
      listed = runs.map do |run|
        created = (run[:created_at] || Time.now).utc.iso8601
        attempt = run.fetch(:attempt, 1)
        path = "GET repos/sorah-rbpkg/build/actions/runs/#{run.fetch(:id)}/attempts/#{attempt}/jobs?per_page=100"
        run.fetch(:jobs).each_slice(100).with_index(1) do |jobs, page|
          s['github'][page == 1 ? path : "#{path}&page=#{page}"] = {'total_count' => run.fetch(:jobs).size, 'jobs' => jobs}
        end
        {'id' => run.fetch(:id), 'run_attempt' => attempt, 'status' => run.fetch(:status, 'in_progress'),
         'conclusion' => run[:conclusion], 'created_at' => created, 'run_started_at' => created, 'updated_at' => Time.now.utc.iso8601}
      end
      s['github']["GET #{BUILD_RUNS}"] = {'workflow_runs' => listed}
    end
  end

  def pending_deployments(run_id, environment_id: 1)
    update_scenario do |s|
      s['github']["GET repos/sorah-rbpkg/build/actions/runs/#{run_id}/pending_deployments"] = [{'environment' => {'id' => environment_id, 'name' => 'release'}}]
    end
  end

  def watch(*args) = bin('releng-watch', '--once', *args)

  def watch_state(version) = JSON.parse(File.read(File.join(build_dir, 'tmp', 'releng-watch', "#{version}.json")))

  def calls
    file = "#{env.fetch('RELENG_FAKE_EXTERNAL')}.calls.jsonl"
    File.exist?(file) ? File.readlines(file).map { JSON.parse(it) } : []
  end

  private

  def save_scenario = File.write(path('scenario.json'), JSON.generate(scenario))

  def setup_gpg
    FileUtils.mkdir_p(path('gnupg'), mode: 0o700)
    sh('gpg', '--batch', '--passphrase', '', '--quick-gen-key', "#{NAME} <#{EMAIL}>", 'ed25519', 'sign', 'never')
    fpr = sh('gpg', '--batch', '--with-colons', '--list-secret-keys')[/^fpr:+(\h{40}):/, 1]
    File.write(path('gitconfig'), <<~CONFIG)
      [user]
        name = #{NAME}
        email = #{EMAIL}
        signingkey = #{fpr}
      [commit]
        gpgsign = true
      [tag]
        gpgSign = true
      [init]
        defaultBranch = main
      [advice]
        detachedHead = false
    CONFIG
  end

  def setup_ruby
    seed = path('seed', 'ruby')
    FileUtils.mkdir_p(File.join(seed, 'debian', 'source'))
    sh('git', 'init', '-q', '-b', 'master', chdir: seed)
    File.write(File.join(seed, 'debian', 'changelog'), <<~CHANGELOG)
      ruby9.9 (9.9.0-0nkmi1~dist) unstable; urgency=medium

        * releng 9.9.0

       -- #{NAME} <#{EMAIL}>  Mon, 16 Nov 2026 00:00:00 +0000
    CHANGELOG
    File.write(File.join(seed, 'debian', 'source', 'format'), "3.0 (quilt)\n")
    sh('git', 'add', '.', chdir: seed)
    sh('git', 'commit', '-q', '-m', 'debian/', chdir: seed)
    sh('git', 'checkout', '-q', '--orphan', 'upstream-9.9', chdir: seed)
    sh('git', 'rm', '-q', '-r', '--cached', '.', chdir: seed)
    sh('git', 'commit', '-q', '--allow-empty', '-m', 'upstream-9.9', chdir: seed)
    sh('git', 'checkout', '-q', '-f', 'master', chdir: seed)
    sh('gbp', 'import-orig', '--no-interactive', '--pristine-tar', '--sign-tags', '--no-symlink-orig',
      '--upstream-branch=upstream-9.9', '--debian-branch=master', '--upstream-tag=upstream/%(version)s',
      '--upstream-version=9.9.0', tarball('9.9.0'), chdir: seed)
    FileUtils.mkdir_p(File.join(seed, 'debian', 'patches'))
    File.write(File.join(seed, 'debian', 'patches', 'series'), "greeting.patch\n")
    File.write(File.join(seed, 'debian', 'patches', 'greeting.patch'), <<~PATCH)
      --- a/lib/greeting.rb
      +++ b/lib/greeting.rb
      @@ -1,3 +1,3 @@
       def greeting
      -  'hello'
      +  'hello, debian'
       end
    PATCH
    sh('git', 'add', '.', chdir: seed)
    sh('git', 'commit', '-q', '-m', 'add greeting.patch', chdir: seed)

    FileUtils.mkdir_p(path('github', 'sorah-rbpkg'))
    sh('git', 'clone', '-q', '--bare', seed, origin('sorah-rbpkg/ruby'))
    sh('git', 'clone', '-q', "file://#{origin('sorah-rbpkg/ruby')}", ruby_dir)
  end

  def setup_build
    files = Open3.capture2('git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', chdir: ROOT).first.split("\0")
    files.each do |f|
      src = File.join(ROOT, f)
      next unless File.file?(src)
      next if f.start_with?('spec/', 'builds/ruby', 'gen/builds/', 'checksums/')

      dst = File.join(build_dir, f)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst, preserve: true)
    end
    FileUtils.mkdir_p([File.join(build_dir, 'gen', 'builds'), File.join(build_dir, 'checksums')])
    File.write(File.join(build_dir, 'keys', 'committers.asc'), sh('gpg', '--batch', '--armor', '--export'))
    File.write(File.join(build_dir, 'builds', 'ruby9.9.jsonnet'), <<~JSONNET)
      local series = import 'series.libsonnet';

      series.ruby(
        '9.9',
        master='master',
        commit='#{git(ruby_dir, 'rev-parse', 'refs/remotes/origin/master')}',
        distros=['trixie'],
        test=false,
      )
    JSONNET
    sh('bin/generate', chdir: build_dir)
    sh('git', 'init', '-q', chdir: build_dir)
    sh('git', 'add', '.', chdir: build_dir)
    sh('git', 'commit', '-q', '-m', 'seed', chdir: build_dir)
    sh('git', 'clone', '-q', '--bare', build_dir, origin('sorah-rbpkg/build'))
    sh('git', 'remote', 'add', 'origin', "file://#{origin('sorah-rbpkg/build')}", chdir: build_dir)
    sh('git', 'fetch', '-q', 'origin', chdir: build_dir)
    sh('git', 'branch', '-q', '--set-upstream-to=origin/main', chdir: build_dir)
  end
end
