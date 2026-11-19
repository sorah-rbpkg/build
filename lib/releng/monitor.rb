# What bin/releng-watch does on each poll: observe, check prerequisites, act on Releng::Watch's decisions.
require 'fileutils'
require 'json'
require 'open3'
require 'set'
require_relative 'external'
require_relative 'watch'
require_relative '../ruby_release'

module Releng
  class Monitor
    BUILD_REPOSITORY = ENV.fetch('GITHUB_REPOSITORY', 'sorah-rbpkg/build')
    REMINDER = 600

    Result = Data.define(:output, :success) do
      def success? = success
    end

    attr_reader :records

    def initialize(root:, source_dir:, versions:, push:, branches: {}, external: External.current, out: $stdout)
      @root = root
      @source_dir = source_dir
      @versions = versions
      @push = push
      @branches = branches
      @external = external
      @out = out
      @dir = File.join(root, 'tmp', 'releng-watch')
      @jobs = {}
      @last_entries = nil
      @reminded_at = 0
      FileUtils.mkdir_p(@dir)
      @records = versions.map { load_record(it) }
    end

    def series(version)
      @series ||= {}
      @series[version] ||= begin
        id = "ruby#{version[/\A\d+\.\d+/]}"
        path = File.join(@root, 'gen', 'builds', "#{id}.json")
        raise "#{version}: no #{path}" unless File.exist?(path)

        JSON.parse(File.read(path)).merge('id' => id).tap { it['master'] = @branches.fetch(version[/\A\d+\.\d+/], it.fetch('master')) }
      end
    end

    def branch(version) = series(version).fetch('master')
    def upstream_branch(version) = "upstream-#{version[/\A\d+\.\d+/]}"

    # One poll. Returns the ACTION REQUIRED list and the seconds until the next poll, or nil once done.
    def poll(min:, max:)
      git(@source_dir, 'fetch', '-q', '--prune', 'origin')
      git(@root, 'fetch', '-q', 'origin')
      blocked, prerequisites = check_prerequisites
      signals = observe

      @records.each do |r|
        s = signals.fetch(r.version)
        decision = Watch.decide(r, s, push: @push)
        if decision.state != r.state
          log("#{r.version}: #{r.state} -> #{decision.state}#{decision.note ? " (#{decision.note})" : ''}")
          r.state = decision.state
          r.note = decision.note if decision.state == 'stopped'
        end
        if decision.action
          missing = Watch::REQUIRES.fetch(decision.action) & blocked.to_a
          if missing.empty?
            log("#{r.version}: #{decision.action}#{decision.note ? " (#{decision.note})" : ''}")
            act(r, decision.action, s)
          else
            log("#{r.version}: #{decision.action} deferred until #{missing.join(', ')} is ready")
          end
        end
        save_record(r)
      end

      # Acting changes what is observed, such as the build of a fresh roll.
      signals = observe
      entries = Watch.entries(records: @records, signals:, series: @versions.to_h { [it, series(it)] }, prerequisites:,
        push: @push, source_dir: @source_dir, build_repository: BUILD_REPOSITORY)
      report(entries, signals)
      done = entries.any? { it.text.start_with?('every distro is released') }
      [entries, done ? nil : Watch.next_check(records: @records, signals:, entries:, now: Time.now.to_i, min:, max:)]
    end

    def status_path = File.join(@dir, 'status.txt')

    private

    def log(message) = @out.puts("[#{Time.now.strftime('%H:%M:%S')}] #{message}")

    def record_path(version) = File.join(@dir, "#{version}.json")

    def load_record(version)
      path = record_path(version)
      return Watch::Record.new(**JSON.parse(File.read(path), symbolize_names: true)) if File.exist?(path)

      reconstruct(version).tap { save_record(it) }
    end

    def save_record(record) = File.write(record_path(record.version), "#{JSON.pretty_generate(record.to_h)}\n")

    # From the refs and this repository alone, for a first run or lost state.
    def reconstruct(version)
      record = Watch::Record.initial(version)
      checksum = committed_checksum(version)
      return record unless checksum&.source == 'draft'

      b = branch(version)
      git(@source_dir, 'fetch', '-q', '--prune', 'origin')
      head = rev(@source_dir, "refs/remotes/origin/draft/#{b}")
      json = "gen/builds/#{series(version).fetch('id')}.json"
      commit = JSON.parse(capture(@root, 'git', 'show', "HEAD:#{json}")).fetch('commit')
      rolled_at = capture(@root, 'git', 'log', '-1', '--format=%ct', '--', json).to_i
      state = if head && head == commit
        'building'
      elsif !head && ancestor?(@source_dir, commit, "refs/remotes/origin/#{b}") &&
          rev(@source_dir, "refs/tags/upstream/#{version}") &&
          ancestor?(@source_dir, "refs/tags/upstream/#{version}", "refs/remotes/origin/#{upstream_branch(version)}")
        'finalized'
      end
      return record unless state

      log("#{version}: resuming as #{state} from the refs")
      record.state = state
      record.sha256 = checksum.sha256
      record.checked_head = record.rolled_head = commit
      record.rolled_at = rolled_at
      record
    end

    def committed_checksum(version)
      out, status = Open3.capture2('git', 'show', "HEAD:checksums/ruby-#{version}.json", chdir: @root, err: File::NULL)
      RubyRelease::Checksum.new(**JSON.parse(out, symbolize_names: true)) if status.success?
    end

    def check_prerequisites
      blocked = Set.new
      texts = []
      unless @external.signing_ok?(@source_dir) && @external.signing_ok?(@root)
        blocked << :signing
        texts << 'unlock your signing key: echo | gpg --clearsign >/dev/null'
      end

      ruby = ruby_problems
      unless ruby.empty?
        blocked << :ruby
        texts.concat(ruby)
      end

      build = build_problems
      unless build.empty?
        blocked << :build
        texts.concat(build)
      end
      [blocked, texts]
    end

    def ruby_problems
      problems = []
      unless capture(@source_dir, 'git', 'status', '--porcelain', '--untracked-files=no').empty?
        problems << "commit or stash in #{@source_dir} (git status)"
      end
      in_progress = %w[rebase-merge rebase-apply MERGE_HEAD].any? do
        File.exist?(File.expand_path(capture(@source_dir, 'git', 'rev-parse', '--git-path', it).strip, @source_dir))
      end
      problems << "finish or abort the rebase or merge in #{@source_dir}" if in_progress
      current = capture(@source_dir, 'git', 'branch', '--show-current').strip
      problems << "gbp pq export, or switch back from #{current}, in #{@source_dir}" if current.start_with?('patch-queue/')

      @versions.flat_map { [branch(it), upstream_branch(it)] }.push('pristine-tar').uniq.each do |b|
        local = rev(@source_dir, "refs/heads/#{b}") or next
        remote = rev(@source_dir, "refs/remotes/origin/#{b}")
        # Behind origin is harmless; commits origin lacks would ride along in a push.
        next if remote && ancestor?(@source_dir, local, remote)

        problems << "push or reset #{b} in #{@source_dir}: it has commits origin lacks (git log origin/#{b}..#{b})"
      end
      @records.each do |r|
        b = "draft/#{branch(r.version)}"
        local = rev(@source_dir, "refs/heads/#{b}")
        remote = rev(@source_dir, "refs/remotes/origin/#{b}")
        next unless local && remote && !ancestor?(@source_dir, remote, local)

        problems << "reset #{b} in #{@source_dir} to origin, as it does not descend from origin's: git checkout #{b} && git reset --hard origin/#{b}"
      end
      problems
    end

    def build_problems
      current = capture(@root, 'git', 'branch', '--show-current').strip
      return ["switch #{@root} to main"] unless current == 'main'

      problems = []
      # bin/import leaves the checksum of a watched version for bin/roll to commit.
      watched = @versions.map { ":(exclude)checksums/ruby-#{it}.json" }
      unless capture(@root, 'git', 'status', '--porcelain', '--', 'builds', 'gen', 'checksums', *watched).empty?
        problems << "commit or discard the changes in builds/ gen/ checksums/ of #{@root}"
      end
      own = monitor_state.fetch('own_commits', [])
      ahead = capture(@root, 'git', 'rev-list', 'refs/remotes/origin/main..main').lines(chomp: true)
      unless (ahead - own).empty?
        problems << "push or drop your unpushed commits on main of #{@root} (git log origin/main..main)"
      end
      problems
    end

    def monitor_state
      path = File.join(@dir, 'monitor.json')
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end

    def update_monitor_state
      state = monitor_state
      yield state
      File.write(File.join(@dir, 'monitor.json'), JSON.generate(state))
    end

    def observe
      releases = optional { RubyRelease.load_releases(RubyRelease.fetch(RubyRelease.releases_url('master'))) } || []
      drafting = optional { @external.github('repos/ruby/actions/actions/workflows/draft-release.yml/runs?per_page=10').fetch('workflow_runs') } || []
      publishing = optional { @external.github('repos/ruby/ruby/actions/workflows/publish.yml/runs?per_page=5').fetch('workflow_runs') } || []
      runs = build_runs if @records.any?(&:rolled_at)

      @records.to_h do |r|
        v = r.version
        s = series(v)
        [v, Watch::Signals.new(
          draft_sha: optional { RubyRelease.draft_info(v)&.dig('sha256', 'gz') },
          published: optional { @external.http_head("https://cache.ruby-lang.org/pub/ruby/#{v[/\A\d+\.\d+/]}/ruby-#{v}.tar.gz") == 200 } || false,
          announced_sha: releases.find { it.fetch('version') == v }&.dig('sha256', 'gz'),
          pr: r.imported? ? optional { pull_request(v) } : nil,
          local_draft_head: rev(@source_dir, "refs/heads/draft/#{branch(v)}"),
          draft_release_running: drafting.any? { Watch::BUSY.include?(it.fetch('status')) && it.fetch('display_title').include?(v) },
          publish_running: publishing.any? { Watch::BUSY.include?(it.fetch('status')) },
          build: r.rolled_at && runs ? Watch.build_status(runs, series_id: s.fetch('id'), distros: s.fetch('distros'), since: r.rolled_at) : nil,
        )]
      end
    end

    # A failed observation is logged and taken as unknown, so a network hiccup only delays a poll's view.
    def optional
      yield
    rescue External::Error => e
      log("warning: #{e.message}")
      nil
    end

    def build_runs
      runs = @external.github("repos/#{BUILD_REPOSITORY}/actions/workflows/build.yml/runs?per_page=20").fetch('workflow_runs')
      runs.map { it.merge('jobs' => run_jobs(it)) }
    rescue External::Error => e
      log("warning: #{e.message}")
      nil
    end

    # Jobs of a finished attempt no longer change.
    def run_jobs(run)
      key = [run.fetch('id'), run.fetch('run_attempt')]
      return @jobs[key] if @jobs.key?(key)

      path = "repos/#{BUILD_REPOSITORY}/actions/runs/#{key[0]}/attempts/#{key[1]}/jobs?per_page=100"
      page = @external.github(path)
      jobs = page.fetch('jobs')
      # A run of several series exceeds one page.
      (2..).each do |n|
        break if jobs.size >= page.fetch('total_count', jobs.size)

        jobs += @external.github("#{path}&page=#{n}").fetch('jobs')
      end
      @jobs[key] = jobs if run.fetch('status') == 'completed'
      jobs
    end

    def pull_request(version)
      prs = @external.github("repos/#{RubyRelease::WWW_REPOSITORY}/pulls?head=ruby:releases/#{version}&state=all")
      pr = prs.find { it.dig('head', 'repo', 'full_name') == RubyRelease::WWW_REPOSITORY } or return
      sha = pr.dig('head', 'sha')
      entries = RubyRelease.load_releases(RubyRelease.fetch(RubyRelease.releases_url(sha)))
      Watch::PullRequest.new(number: pr.fetch('number'), url: pr.fetch('html_url'),
        sha256: entries.find { it.fetch('version') == version }&.dig('sha256', 'gz'),
        created_at: Time.parse(pr.fetch('created_at')).to_i, updated_at: Time.parse(pr.fetch('updated_at')).to_i)
    end

    def act(r, action, s)
      r.acted_at = Time.now.to_i
      if !@push && %i[discard finalize].include?(action)
        r.note = "push it yourself (--no-push): bin/import --#{action} #{r.version}"
        return
      end
      send(:"act_#{action}", r, s)
    end

    def act_import_draft(r, s)
      if script('import', '--draft', *branch_args(r), '--source-dir', @source_dir, r.version).success?
        r.sha256 = s.draft_sha
        r.failures = 0
        r.note = nil
        act_check_patches(r, s)
      else
        script('import', '--discard', '--yes', *branch_args(r), '--source-dir', @source_dir, r.version)
        fail(r, "bin/import --draft #{r.version} failed")
      end
    end

    def act_check_patches(r, _s)
      head = rev(@source_dir, "refs/heads/draft/#{branch(r.version)}")
      ok = script('check-patches', '--source-dir', @source_dir, "draft/#{branch(r.version)}").success?
      r.checked_head = head
      r.state = ok ? 'drafted' : 'paused_patches'
      log("#{r.version}: #{r.state}")
    end

    def act_push_and_roll(r, _s)
      b = branch(r.version)
      return fail(r, "bin/import --push --draft #{r.version} failed") unless script('import', '--push', '--draft', '--yes', *branch_args(r), '--source-dir', @source_dir, r.version).success?

      before = rev(@root, 'HEAD')
      return fail(r, "bin/roll draft/#{b} failed") unless script('roll', '--source-dir', @source_dir, "draft/#{b}").success?

      if rev(@root, 'HEAD') != before
        update_monitor_state { it['own_commits'] = [*it['own_commits'], rev(@root, 'HEAD')] }
        return fail(r, 'git push origin main failed') unless push_main
        r.rolled_at = Time.now.to_i
      end
      r.rolled_at ||= Time.now.to_i
      r.rolled_head = rev(@source_dir, "refs/heads/draft/#{b}")
      r.state = 'building'
      r.failures = 0
      r.note = nil
    end

    def push_main
      return true if run(@root, 'git', 'push', '-q', 'origin', 'main')

      run(@root, 'git', 'fetch', '-q', 'origin')
      unless run(@root, 'git', 'rebase', '-q', 'refs/remotes/origin/main')
        run(@root, 'git', 'rebase', '--abort')
        return false
      end
      update_monitor_state { it['own_commits'] = capture(@root, 'git', 'rev-list', 'refs/remotes/origin/main..main').lines(chomp: true) }
      run(@root, 'git', 'push', '-q', 'origin', 'main')
    end

    def act_discard(r, _s)
      return fail(r, "bin/import --discard #{r.version} failed") unless script('import', '--discard', '--yes', *branch_args(r), '--source-dir', @source_dir, r.version).success?

      r.note = nil
      reject_approvals(r) if r.rolled_at
      r.state = 'waiting_draft'
      r.sha256 = r.checked_head = r.rolled_head = r.rolled_at = nil
      r.failures = 0
    end

    def act_finalize(r, _s)
      result = script('import', '--finalize', '--yes', *branch_args(r), '--source-dir', @source_dir, r.version)
      if result.success?
        r.state = 'finalized'
        r.failures = 0
        r.note = nil
        return
      end

      b = branch(r.version)
      case result.output
      when /has moved past/
        r.note = "#{b} on origin moved past draft/#{b}: cd #{@source_dir} && git checkout draft/#{b} && " \
          "git rebase origin/#{b} && git push --force-with-lease origin draft/#{b}"
      when /sha256 is \h+, not \h+ from/
        r.state = 'stopped'
        r.note = "the published tarball differs from the draft that was built: bin/import --discard --yes #{r.version}, then bin/import #{r.version} and bin/roll #{b}"
      else
        fail(r, "bin/import --finalize #{r.version} failed")
      end
    end

    # A run waiting on other series as well is left to a person, since a rejection covers the whole run.
    def reject_approvals(r)
      runs = build_runs or return
      series_id = series(r.version).fetch('id')
      runs.each do |run|
        next unless Time.parse(run.fetch('created_at')).to_i >= r.rolled_at

        waiting = run.fetch('jobs').select { it.fetch('status') == 'waiting' }
        next if waiting.empty?

        url = "https://github.com/#{BUILD_REPOSITORY}/actions/runs/#{run.fetch('id')}"
        unless waiting.all? { Watch.job_of?(it, series_id) }
          r.note = "reject the #{series_id} release jobs of #{url} yourself; it waits on other series too"
          next
        end
        path = "repos/#{BUILD_REPOSITORY}/actions/runs/#{run.fetch('id')}/pending_deployments"
        ids = @external.github(path).map { it.dig('environment', 'id') }.uniq
        @external.github(path, method: 'POST', fields: {environment_ids: ids, state: 'rejected', comment: "ruby #{r.version} was re-cut upstream"})
        log("#{r.version}: rejected the pending release of #{url}")
      end
    end

    def fail(r, message)
      r.failures = (r.failures || 0) + 1
      log("#{r.version}: #{message} (#{r.failures} in a row)")
      r.note = "#{message} #{r.failures} times in a row; see the log above" if r.failures >= 5
      false
    end

    def report(entries, signals)
      lines = entries.map { format('[%-7s] %s', it.scope, it.text) }
      progress = @records.map do |r|
        build = signals.fetch(r.version).build
        counts = build ? build.statuses.tally.map { |k, n| "#{n} #{k}" }.join(', ') : '-'
        "#{r.version}: #{r.state} (build: #{counts})"
      end
      File.write(status_path, [*progress, '', *(lines.empty? ? ['no action required'] : ["ACTION REQUIRED (#{lines.size})", *lines])].join("\n") + "\n")

      changed = lines != @last_entries
      return unless changed || (!lines.empty? && Time.now.to_i - @reminded_at >= REMINDER)

      @last_entries = lines
      @reminded_at = Time.now.to_i
      @out.puts(*progress)
      if lines.empty?
        @out.puts('no action required')
      else
        @out.print("\a") if changed && @out.tty?
        @out.puts("── ACTION REQUIRED (#{lines.size}) ".ljust(72, '─'), *lines, '─' * 72)
      end
    end

    def branch_args(r)
      series = r.version[/\A\d+\.\d+/]
      @branches.key?(series) ? ['--branch', "#{series}=#{@branches.fetch(series)}"] : []
    end

    def script(name, *args)
      @out.puts("  $ bin/#{name} #{args.join(' ')}")
      output = +''
      status = Open3.popen2e(File.join(@root, 'bin', name), *args, chdir: @root) do |stdin, io, thread|
        stdin.close
        io.each_line do |line|
          output << line
          @out.puts("  │ #{line}")
        end
        thread.value
      end
      Result.new(output:, success: status.success?)
    end

    def run(dir, *cmd) = system(*cmd, chdir: dir, out: File::NULL, err: File::NULL)

    def git(dir, *args)
      out, status = Open3.capture2e('git', *args, chdir: dir)
      raise External::Error, "git #{args.join(' ')} in #{dir}: #{out.strip}" unless status.success?
      out
    end

    def capture(dir, *cmd)
      out, status = Open3.capture2(*cmd, chdir: dir)
      raise "#{cmd.join(' ')} failed in #{dir}" unless status.success?
      out
    end

    def rev(dir, ref)
      out, status = Open3.capture2('git', 'rev-parse', '--verify', '-q', ref, chdir: dir)
      status.success? ? out.strip : nil
    end

    def ancestor?(dir, a, b) = run(dir, 'git', 'merge-base', '--is-ancestor', a, b)
  end
end
