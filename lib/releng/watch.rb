# The decisions of bin/releng-watch, apart from the observing and acting it does, so they can be tested alone.
require 'time'

module Releng
  module Watch
    # What the monitor knows of a version between polls, persisted in tmp/releng-watch/<version>.json.
    # sha256 is that of the draft it imported; checked_head and rolled_head are draft/<branch> commits.
    Record = Struct.new(:version, :state, :sha256, :checked_head, :rolled_head, :rolled_at, :acted_at, :failures, :note, keyword_init: true) do
      def self.initial(version) = new(version:, state: 'waiting_draft', failures: 0)
      def imported? = !sha256.nil?
    end

    # One poll's view of a version.
    Signals = Data.define(
      :draft_sha, :published, :announced_sha, :pr, :local_draft_head,
      :draft_release_running, :publish_running, :build,
    ) do
      def self.empty = new(draft_sha: nil, published: false, announced_sha: nil, pr: nil, local_draft_head: nil,
        draft_release_running: false, publish_running: false, build: nil)
    end

    # A www.ruby-lang.org pull request adding the release, with the sha256 its releases.yml gives at its head.
    PullRequest = Data.define(:number, :url, :sha256, :created_at, :updated_at)

    # The newest build of each distro of a series since its roll, plus timings for the poll interval.
    Distro = Data.define(:name, :status, :run_id, :attempt, :failed_jobs)
    Build = Data.define(:distros, :started_at, :median_seconds) do
      def statuses = distros.map(&:status)
      def failed = distros.select { it.status == :failed }
      def running? = statuses.include?(:building) || statuses.include?(:pending)
    end

    Decision = Data.define(:action, :state, :note) do
      def self.wait(state, note = nil) = new(action: nil, state:, note:)
    end

    # Which prerequisites each action needs, so a failing one only defers what it would break.
    REQUIRES = {
      import_draft: %i[signing ruby],
      discard: %i[ruby],
      check_patches: [],
      push_and_roll: %i[signing ruby build],
      finalize: %i[signing ruby],
    }.freeze

    FINAL_STATES = %w[finalized announced].freeze

    # The next step for a version, from its record and this poll's signals.
    def self.decide(record, signals, push:)
      state = record.state
      return Decision.wait(state) if state == 'stopped'

      case state
      when 'announced'
        return Decision.wait(state)
      when 'finalized'
        return Decision.wait('announced') if signals.announced_sha == record.sha256
        if signals.announced_sha
          return Decision.new(action: nil, state: 'stopped',
            note: "master's releases.yml lists sha256 #{signals.announced_sha}, not #{record.sha256} as built")
        end

        return Decision.wait(state)
      end

      unless record.imported?
        return Decision.new(action: :import_draft, state:, note: nil) if signals.draft_sha
        if signals.published
          return Decision.new(action: nil, state: 'stopped',
            note: 'published without a draft imported here; bin/import VERSION, then bin/roll BRANCH')
        end

        return Decision.wait(state)
      end

      # Once published, the draft is gone from pub/tmp/ and the published tarball is checked by --finalize.
      unless signals.published
        return Decision.new(action: :discard, state:, note: 'the draft is gone from pub/tmp/') unless signals.draft_sha
        if signals.draft_sha != record.sha256
          return Decision.new(action: :discard, state:, note: "the draft was re-cut: sha256 #{signals.draft_sha}, not #{record.sha256}")
        end
      end

      case state
      when 'paused_patches'
        signals.local_draft_head == record.checked_head ? Decision.wait(state) : Decision.new(action: :check_patches, state:, note: nil)
      when 'drafted'
        push ? Decision.new(action: :push_and_roll, state:, note: nil) : Decision.wait(state)
      when 'building'
        if signals.local_draft_head && signals.local_draft_head != record.rolled_head
          Decision.new(action: :check_patches, state:, note: nil)
        elsif signals.published
          Decision.new(action: :finalize, state:, note: nil)
        else
          Decision.wait(state)
        end
      else
        raise "unknown state #{state}"
      end
    end

    BUSY = %w[queued in_progress waiting requested pending].freeze
    FAILED = %w[failure cancelled timed_out startup_failure].freeze

    # The latest attempt of the newest run since the roll decides each distro. A distro missing from the
    # series' newest run was released before, as bin/plan leaves those out.
    def self.build_status(runs, series_id:, distros:, since:)
      series_runs = runs.select { |run| Time.parse(run.fetch('created_at')).to_i >= since && run.fetch('jobs').any? { job_of?(it, series_id) } }
        .sort_by { Time.parse(it.fetch('created_at')) }.reverse
      statuses = distros.map do |name|
        run = series_runs.find { |r| r.fetch('jobs').any? { job_of?(it, series_id, name) } }
        next Distro.new(name:, status: series_runs.empty? ? :pending : :released, run_id: nil, attempt: nil, failed_jobs: []) unless run

        jobs = run.fetch('jobs').select { job_of?(it, series_id, name) }
        release = jobs.find { it.fetch('name').end_with?('/ release') }
        failed = jobs.select { FAILED.include?(it['conclusion']) }.map { it.fetch('name') }
        status = case
        when release&.fetch('status') == 'waiting' then :awaiting_approval
        when release&.fetch('conclusion') == 'success' then :released
        when jobs.any? { BUSY.include?(it.fetch('status')) } then :building
        when !failed.empty? || release.nil? || release['conclusion'] == 'skipped' then :failed
        else :building
        end
        Distro.new(name:, status:, run_id: run.fetch('id'), attempt: run.fetch('run_attempt'), failed_jobs: failed)
      end

      newest = series_runs.find { BUSY.include?(it.fetch('status')) }
      durations = runs.select { it['conclusion'] == 'success' && it.fetch('jobs').any? { job_of?(it, series_id) } }
        .first(3).map { Time.parse(it.fetch('updated_at')) - Time.parse(it.fetch('run_started_at')) }.sort
      Build.new(distros: statuses, started_at: newest && Time.parse(newest.fetch('run_started_at')).to_i,
        median_seconds: durations.empty? ? nil : durations[durations.size / 2])
    end

    # Job names are "<series> <distro> / <job>", with " (test)" after the distro in test mode.
    def self.job_of?(job, series_id, distro = nil)
      name = job.fetch('name')
      prefix = distro ? "#{series_id} #{distro}" : "#{series_id} "
      distro ? name.start_with?("#{prefix} / ", "#{prefix} (test) / ") : name.start_with?(prefix)
    end

    Entry = Data.define(:scope, :text)

    # The ACTION REQUIRED list for one poll.
    def self.entries(records:, signals:, series:, prerequisites:, push:, source_dir:, build_repository:)
      list = prerequisites.map { Entry.new(scope: 'all', text: it) }
      records.each do |r|
        s = signals.fetch(r.version)
        branch = series.fetch(r.version).fetch('master')
        add = ->(text) { list << Entry.new(scope: r.version, text:) }
        case r.state
        when 'stopped'
          add.("stopped: #{r.note}; once resolved: bin/releng-watch --reset #{r.version}")
        when 'paused_patches'
          add.("debian/patches fails on draft/#{branch}: cd #{source_dir} && git checkout draft/#{branch} && " \
            'gbp pq import --force --time-machine=5 && gbp pq rebase && gbp pq export && git commit -a')
        when 'drafted'
          add.("push it yourself (--no-push): bin/import --push --draft #{r.version} && bin/roll draft/#{branch} && git push origin main") unless push
        end
        add.(r.note) if r.note && r.state != 'stopped'
        s.build&.failed&.each do |d|
          add.("build of #{series.fetch(r.version).fetch('id')} #{d.name} failed (#{d.failed_jobs.join(', ')}): " \
            "gh run rerun #{d.run_id} --failed, or commit a fix on draft/#{branch}")
        end
      end

      builds = records.map { signals.fetch(it.version).build }
      ready = builds.all? { it && it.distros.all? { %i[awaiting_approval released].include?(it.status) } }
      if ready && records.all? { it.state == 'announced' }
        waiting = builds.flat_map(&:distros).select { it.status == :awaiting_approval }
        if waiting.empty?
          list << Entry.new(scope: 'all', text: 'every distro is released: bin/publish')
        else
          urls = waiting.map(&:run_id).uniq.map { "https://github.com/#{build_repository}/actions/runs/#{it}" }
          list << Entry.new(scope: 'all', text: "approve every release job at once: #{urls.join(' ')}")
        end
      end
      list
    end

    ACTED_WINDOW = 180
    FAST = 20

    # Seconds until the next poll: relaxed while nothing moves, frequent once something is about to.
    def self.next_check(records:, signals:, entries:, now:, min:, max:)
      waits = records.map do |r|
        s = signals.fetch(r.version)
        build = s.build
        case
        when r.acted_at && now - r.acted_at < ACTED_WINDOW then FAST
        when r.state == 'waiting_draft' then s.draft_release_running ? FAST : 600
        when build&.running?
          elapsed = build.started_at ? now - build.started_at : 0
          build.median_seconds && elapsed > build.median_seconds * 0.8 ? 60 : 300
        when !FINAL_STATES.include?(r.state) && (s.publish_running || (s.pr && now - s.pr.created_at < 1800)) then FAST
        when !FINAL_STATES.include?(r.state) && s.draft_release_running then 300
        when r.state == 'finalized' then s.pr && now - s.pr.updated_at < 600 ? 60 : 300
        else 600
        end
      end
      waits << FAST if entries.any? { !it.text.start_with?('approve every release job', 'every distro is released') }
      waits.min.clamp(min, max)
    end
  end
end
