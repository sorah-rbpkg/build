require_relative '../../../lib/releng/watch'

RSpec.describe Releng::Watch do
  let(:now) { 1_800_000_000 }

  def record(**) = Releng::Watch::Record.new(version: '9.9.1', state: 'waiting_draft', failures: 0, **)
  def signals(**) = Releng::Watch::Signals.empty.with(**)

  describe '.decide' do
    def decide(r, s, push: true) = described_class.decide(r, s, push:)

    it 'waits for a draft, then imports it' do
      expect(decide(record, signals)).to have_attributes(action: nil, state: 'waiting_draft')
      expect(decide(record, signals(draft_sha: 'a'))).to have_attributes(action: :import_draft)
    end

    it 'stops on a release published without an imported draft' do
      expect(decide(record, signals(published: true))).to have_attributes(state: 'stopped', note: include('bin/import VERSION'))
    end

    it 'discards a re-cut or abandoned draft before publish' do
      r = record(state: 'building', sha256: 'a', rolled_head: 'h')
      expect(decide(r, signals(draft_sha: 'b', local_draft_head: 'h'))).to have_attributes(action: :discard, note: include('re-cut'))
      expect(decide(r, signals(local_draft_head: 'h'))).to have_attributes(action: :discard, note: include('gone'))
    end

    it 'does not take the draft leaving pub/tmp/ at publish as abandonment' do
      r = record(state: 'building', sha256: 'a', rolled_head: 'h')
      expect(decide(r, signals(published: true, local_draft_head: 'h'))).to have_attributes(action: :finalize)
    end

    it 'resumes paused patches only once the draft head moves' do
      r = record(state: 'paused_patches', sha256: 'a', checked_head: 'h')
      expect(decide(r, signals(draft_sha: 'a', local_draft_head: 'h')).action).to be_nil
      expect(decide(r, signals(draft_sha: 'a', local_draft_head: 'i')).action).to eq(:check_patches)
    end

    it 'pushes and rolls a drafted version unless --no-push' do
      r = record(state: 'drafted', sha256: 'a')
      expect(decide(r, signals(draft_sha: 'a')).action).to eq(:push_and_roll)
      expect(decide(r, signals(draft_sha: 'a'), push: false).action).to be_nil
    end

    it 're-checks a building version whose draft head moved' do
      r = record(state: 'building', sha256: 'a', rolled_head: 'h')
      expect(decide(r, signals(draft_sha: 'a', local_draft_head: 'i', published: true)).action).to eq(:check_patches)
    end

    it 'announces a finalized version once master lists its checksum, and stops on another' do
      r = record(state: 'finalized', sha256: 'a')
      expect(decide(r, signals).state).to eq('finalized')
      expect(decide(r, signals(announced_sha: 'a')).state).to eq('announced')
      expect(decide(r, signals(announced_sha: 'b'))).to have_attributes(state: 'stopped', note: include('lists sha256 b'))
    end

    it 'does nothing for a stopped version' do
      expect(decide(record(state: 'stopped', sha256: 'a'), signals(draft_sha: 'b'))).to have_attributes(action: nil, state: 'stopped')
    end
  end

  describe '.build_status' do
    def job(name, status: 'completed', conclusion: 'success') = {'name' => "ruby9.9 #{name}", 'status' => status, 'conclusion' => conclusion}

    def run(id, created, jobs, attempt: 1, status: 'in_progress', conclusion: nil, finished: created + 1800)
      {'id' => id, 'run_attempt' => attempt, 'status' => status, 'conclusion' => conclusion, 'jobs' => jobs,
       'created_at' => Time.at(created).utc.iso8601, 'run_started_at' => Time.at(created).utc.iso8601,
       'updated_at' => Time.at(finished).utc.iso8601}
    end

    def status(runs, since: now - 3600) = described_class.build_status(runs, series_id: 'ruby9.9', distros: %w[trixie noble], since:)

    it 'takes the newest run since the roll for each distro' do
      runs = [
        run(2, now - 60, [job('trixie / build (amd64)', status: 'in_progress', conclusion: nil)]),
        run(1, now - 600, [job('trixie / release', status: 'waiting', conclusion: nil), job('noble / release', status: 'waiting', conclusion: nil)]),
        run(0, now - 7200, [job('trixie / build (amd64)', conclusion: 'failure')]),
      ]
      build = status(runs)
      expect(build.distros.to_h { [it.name, [it.status, it.run_id]] }).to eq('trixie' => [:building, 2], 'noble' => [:awaiting_approval, 1])
    end

    it 'counts a distro missing from the newest run as released before' do
      build = status([run(1, now - 60, [job('trixie / release')], status: 'completed', conclusion: 'success')])
      expect(build.distros.map(&:status)).to eq(%i[released released])
    end

    it 'is pending before any run since the roll' do
      expect(status([run(0, now - 7200, [job('trixie / release')])]).statuses).to eq(%i[pending pending])
    end

    it 'fails a distro with a failed job and no release waiting, naming the jobs' do
      build = status([run(1, now - 60, [job('trixie / build (arm64)', conclusion: 'failure'), job('trixie / release', conclusion: 'skipped'),
        job('noble / release', status: 'waiting', conclusion: nil)], status: 'completed', conclusion: 'failure')])
      expect(build.failed.map { [it.name, it.failed_jobs] }).to eq([['trixie', ['ruby9.9 trixie / build (arm64)']]])
    end

    it 'waits for approval despite a failed smoke test, as smoke-warn lets the release through' do
      build = status([run(1, now - 60, [job('trixie / smoke (amd64)', conclusion: 'failure'), job('trixie / release', status: 'waiting', conclusion: nil)])])
      expect(build.distros.first.status).to eq(:awaiting_approval)
    end

    it 'follows the latest attempt of a rerun' do
      build = status([run(1, now - 60, [job('trixie / build (arm64)', status: 'in_progress', conclusion: nil)], attempt: 2)])
      expect(build.distros.first).to have_attributes(status: :building, attempt: 2)
    end

    it 'ignores other series and test runs of other distros' do
      other = {'name' => 'ruby9.8 trixie / release', 'status' => 'waiting', 'conclusion' => nil}
      build = status([run(1, now - 60, [other, job('trixie (test) / release', status: 'waiting', conclusion: nil)])])
      expect(build.distros.map(&:status)).to eq(%i[awaiting_approval released])
    end

    it 'takes the median of the last three successful runs' do
      runs = [1200, 2400, 1800, 9999].each_with_index.map do |d, i|
        run(i, now - (10_000 * (i + 1)), [job('trixie / release')], status: 'completed', conclusion: 'success', finished: now - (10_000 * (i + 1)) + d)
      end
      expect(status(runs).median_seconds).to eq(1800)
    end
  end

  describe '.entries' do
    let(:series) { {'9.9.1' => {'id' => 'ruby9.9', 'master' => 'master'}, '9.8.1' => {'id' => 'ruby9.8', 'master' => 'master-9.8'}} }

    def distro(status, run_id = 1) = Releng::Watch::Distro.new(name: 'trixie', status:, run_id:, attempt: 1, failed_jobs: ['ruby9.9 trixie / build'])
    def build(*distros) = Releng::Watch::Build.new(distros:, started_at: nil, median_seconds: nil)

    def entries(records, builds, prerequisites: [], push: true)
      described_class.entries(records:, signals: records.to_h { [it.version, signals(build: builds.fetch(it.version))] },
        series:, prerequisites:, push:, source_dir: '../ruby', build_repository: 'sorah-rbpkg/build').map(&:text)
    end

    let(:records) { [record(state: 'announced'), record(version: '9.8.1', state: 'announced')] }

    it 'asks for the batch approval only once every distro of every version waits' do
      expect(entries(records, {'9.9.1' => build(distro(:awaiting_approval, 1)), '9.8.1' => build(distro(:building, 2))})).to be_empty
      expect(entries(records, {'9.9.1' => build(distro(:awaiting_approval, 1)), '9.8.1' => build(distro(:awaiting_approval, 2))}))
        .to eq(['approve every release job at once: https://github.com/sorah-rbpkg/build/actions/runs/1 https://github.com/sorah-rbpkg/build/actions/runs/2'])
    end

    it 'holds the batch approval until every version is announced' do
      not_yet = [record(state: 'finalized'), records.last]
      expect(entries(not_yet, {'9.9.1' => build(distro(:awaiting_approval)), '9.8.1' => build(distro(:awaiting_approval))})).to be_empty
    end

    it 'points at bin/publish once everything is released' do
      expect(entries(records, {'9.9.1' => build(distro(:released)), '9.8.1' => build(distro(:released))})).to eq(['every distro is released: bin/publish'])
    end

    it 'lists prerequisites, paused versions, failed builds and notes' do
      list = entries([record(state: 'paused_patches', sha256: 'a'), record(version: '9.8.1', state: 'building', sha256: 'b', note: 'a note')],
        {'9.9.1' => nil, '9.8.1' => build(distro(:failed, 5))}, prerequisites: ['unlock your signing key'])
      expect(list).to include('unlock your signing key', 'a note', 'build of ruby9.8 trixie failed (ruby9.9 trixie / build): gh run rerun 5 --failed, or commit a fix on draft/master-9.8')
      expect(list.grep(/debian\/patches fails on draft\/master: cd \.\.\/ruby/)).not_to be_empty
    end

    it 'prints the pushes of a drafted version with --no-push' do
      list = entries([record(state: 'drafted', sha256: 'a')], {'9.9.1' => nil}, push: false)
      expect(list).to eq(['push it yourself (--no-push): bin/import --push --draft 9.9.1 && bin/roll draft/master && git push origin main'])
    end
  end

  describe '.next_check' do
    def next_check(r, s, entries: []) = described_class.next_check(records: [r], signals: {'9.9.1' => s}, entries:, now:, min: 15, max: 600)
    def pr(age) = Releng::Watch::PullRequest.new(number: 1, url: 'u', sha256: 'a', created_at: now - age, updated_at: now - age)
    def build(started_ago, median) = Releng::Watch::Build.new(distros: [Releng::Watch::Distro.new(name: 'trixie', status: :building, run_id: 1, attempt: 1, failed_jobs: [])],
      started_at: now - started_ago, median_seconds: median)

    it 'relaxes to the maximum while idle' do
      expect(next_check(record, signals)).to eq(600)
    end

    it 'polls fast while a draft is being uploaded' do
      expect(next_check(record, signals(draft_release_running: true))).to eq(20)
    end

    it 'polls fast for a while after acting' do
      expect(next_check(record(state: 'building', acted_at: now - 60), signals)).to eq(20)
    end

    it 'polls the build every five minutes, then every minute near its usual length' do
      r = record(state: 'building', sha256: 'a')
      expect(next_check(r, signals(build: build(300, 2400)))).to eq(300)
      expect(next_check(r, signals(build: build(2000, 2400)))).to eq(60)
    end

    it 'polls fast while publishing or just after the pull request appears' do
      r = record(state: 'building', sha256: 'a')
      expect(next_check(r, signals(publish_running: true))).to eq(20)
      expect(next_check(r, signals(pr: pr(60)))).to eq(20)
      expect(next_check(r, signals(pr: pr(7200)))).to eq(600)
    end

    it 'polls the announcement every minute while its pull request is active' do
      r = record(state: 'finalized', sha256: 'a')
      expect(next_check(r, signals(pr: pr(60)))).to eq(60)
      expect(next_check(r, signals(pr: pr(7200)))).to eq(300)
    end

    it 'polls fast while a person has something to do, except approving' do
      approve = Releng::Watch::Entry.new(scope: 'all', text: 'approve every release job at once: x')
      unlock = Releng::Watch::Entry.new(scope: 'all', text: 'unlock your signing key')
      expect(next_check(record, signals, entries: [approve])).to eq(600)
      expect(next_check(record, signals, entries: [unlock])).to eq(20)
    end

    it 'clamps to the interval bounds' do
      expect(described_class.next_check(records: [record], signals: {'9.9.1' => signals(draft_release_running: true)}, entries: [], now:, min: 30, max: 60)).to eq(30)
    end
  end
end
