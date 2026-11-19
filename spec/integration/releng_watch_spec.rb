require 'json'

RSpec.describe 'bin/releng-watch' do
  let(:world) { World.create }
  let(:ruby) { world.ruby_dir }

  after { world.cleanup }

  def watch(*args)
    result = world.watch(*args, '9.9.1')
    expect(result).to be_success, result.output
    result.output
  end

  def state = world.watch_state('9.9.1')
  def origin_rev(ref) = world.rev(world.origin('sorah-rbpkg/ruby'), ref)
  def build_origin_series = JSON.parse(world.git(world.origin('sorah-rbpkg/build'), 'show', 'main:gen/builds/ruby9.9.json'))
  def awaiting(id: 100, **) = world.build_runs({id:, jobs: world.distro_jobs('ruby9.9', 'trixie'), **})

  # Draft, patches checked, pushed and rolled: two polls.
  def building
    world.draft('9.9.1')
    watch
    expect(state).to include('state' => 'drafted')
    watch
    expect(state).to include('state' => 'building')
  end

  it 'follows a release from its draft to the batch approval and bin/publish' do
    world.draft('9.9.1')
    watch
    expect(state).to include('state' => 'drafted', 'sha256' => Digest::SHA256.file(world.tarball('9.9.1')).hexdigest)

    watch
    expect(state).to include('state' => 'building')
    expect(origin_rev('refs/heads/draft/master')).to eq(build_origin_series.fetch('commit'))
    expect(world.git(world.origin('sorah-rbpkg/build'), 'show', '--name-only', '--format=%s', 'main')).to include('checksums/ruby-9.9.1.json')

    awaiting(status: 'in_progress')
    world.pull_request('9.9.1', number: 4100)
    out = watch
    expect(out).to include('no action required')

    world.publish('9.9.1')
    watch
    expect(state).to include('state' => 'finalized')
    expect(origin_rev('refs/heads/master')).to eq(build_origin_series.fetch('commit'))
    expect(origin_rev('refs/heads/draft/master')).to be_nil

    world.announce('9.9.1')
    out = watch
    expect(state).to include('state' => 'announced')
    expect(out).to include('approve every release job at once: https://github.com/sorah-rbpkg/build/actions/runs/100')

    world.build_runs({id: 100, status: 'completed', conclusion: 'success', jobs: world.distro_jobs('ruby9.9', 'trixie', release: :success)})
    expect(watch).to include('every distro is released; run bin/publish')
  end

  it 'holds the batch approval while another distro still builds' do
    building
    world.publish('9.9.1')
    world.announce('9.9.1')
    world.build_runs({id: 100, jobs: world.distro_jobs('ruby9.9', 'trixie', release: nil, 'build (arm64)' => {status: 'in_progress', conclusion: nil})})
    watch
    out = watch
    expect(state).to include('state' => 'announced')
    expect(out).not_to include('approve every release job')
    expect(out).to include('1 building')
  end

  it 'follows a run whose jobs span more than one page' do
    building
    others = (1..20).flat_map { world.distro_jobs('ruby9.8', "distro#{it}") }
    world.build_runs({id: 100, jobs: others + world.distro_jobs('ruby9.9', 'trixie')})
    expect(watch).to include('9.9.1: building (build: 1 awaiting_approval)')
  end

  it 'discards a re-cut draft, rejects its pending release and builds the new one' do
    building
    awaiting
    world.pending_deployments(100, environment_id: 7)
    recut = world.tarball('9.9.1', cut: 2)
    world.draft('9.9.1', tarball: recut)

    watch
    expect(state).to include('state' => 'waiting_draft', 'sha256' => nil)
    expect(world.calls).to include(include('method' => 'POST', 'path' => 'repos/sorah-rbpkg/build/actions/runs/100/pending_deployments',
      'fields' => include('environment_ids' => [7], 'state' => 'rejected')))

    world.build_runs
    watch
    watch
    expect(state).to include('state' => 'building', 'sha256' => Digest::SHA256.file(recut).hexdigest)
    expect(JSON.parse(world.git(world.origin('sorah-rbpkg/build'), 'show', 'main:checksums/ruby-9.9.1.json')))
      .to include('sha256' => Digest::SHA256.file(recut).hexdigest, 'source' => 'draft')
  end

  it 'leaves the rejection of a run shared with another series to a person' do
    building
    world.build_runs({id: 100, jobs: world.distro_jobs('ruby9.9', 'trixie') + world.distro_jobs('ruby9.8', 'trixie')})
    world.draft('9.9.1', tarball: world.tarball('9.9.1', cut: 2))
    watch
    expect(world.calls).to be_empty
    expect(state.fetch('note')).to include('reject the ruby9.9 release jobs of https://github.com/sorah-rbpkg/build/actions/runs/100 yourself')
  end

  it 'pauses on debian/patches and resumes once a fix is committed on the draft branch' do
    world.draft('9.9.1', tarball: world.tarball('9.9.1', greeting: 'hi'))
    out = watch
    expect(state).to include('state' => 'paused_patches')
    expect(out).to include('debian/patches fails on draft/master', 'gbp pq import')
    expect(watch).to include('ACTION REQUIRED')

    world.git(ruby, 'checkout', '-q', 'draft/master')
    patch = File.join(ruby, 'debian', 'patches', 'greeting.patch')
    File.write(patch, File.read(patch).sub("-  'hello'", "-  'hi'"))
    world.git(ruby, 'commit', '-q', '-am', 'refresh greeting.patch')

    watch
    expect(state).to include('state' => 'drafted')
    watch
    expect(state).to include('state' => 'building')
    expect(build_origin_series.fetch('commit')).to eq(world.rev(ruby, 'refs/heads/draft/master'))
  end

  it 'lists a failed build with its rerun and clears it once a new attempt builds' do
    building
    world.build_runs({id: 100, status: 'completed', conclusion: 'failure',
      jobs: world.distro_jobs('ruby9.9', 'trixie', release: :skipped, 'build (arm64)' => {conclusion: 'failure'})})
    expect(watch).to include('build of ruby9.9 trixie failed (ruby9.9 trixie / build (arm64)): gh run rerun 100 --failed')

    world.build_runs({id: 100, attempt: 2, jobs: world.distro_jobs('ruby9.9', 'trixie')})
    expect(watch).not_to include('build of ruby9.9 trixie failed')
  end

  it 'asks for a rebase when the real branch moved before finalize' do
    building
    other = world.path('other')
    world.sh('git', 'clone', '-q', "file://#{world.origin('sorah-rbpkg/ruby')}", other)
    world.sh('git', 'commit', '-q', '--allow-empty', '-m', 'moved', chdir: other)
    world.sh('git', 'push', '-q', 'origin', 'master', chdir: other)
    world.publish('9.9.1')

    out = watch
    expect(state).to include('state' => 'building')
    expect(out).to include('git rebase origin/master && git push --force-with-lease origin draft/master')

    world.git(ruby, 'fetch', '-q', 'origin')
    world.git(ruby, 'checkout', '-q', 'draft/master')
    world.git(ruby, 'rebase', '-q', 'origin/master')
    world.git(ruby, 'push', '-q', '--force-with-lease', 'origin', 'draft/master')
    watch
    watch
    expect(build_origin_series.fetch('commit')).to eq(world.rev(ruby, 'refs/heads/draft/master'))
    watch
    expect(state).to include('state' => 'finalized')
  end

  it 'stops when the published tarball differs from the draft it built' do
    building
    world.publish('9.9.1', tarball: world.tarball('9.9.1', cut: 2))
    out = watch
    expect(state).to include('state' => 'stopped')
    expect(out).to include('the published tarball differs from the draft that was built')
    expect(origin_rev('refs/heads/draft/master')).not_to be_nil
  end

  it 'stops when the announcement lists another checksum' do
    building
    world.publish('9.9.1')
    watch
    world.announce('9.9.1', tarball: world.tarball('9.9.1', cut: 2))
    watch
    expect(state).to include('state' => 'stopped')
    expect(state.fetch('note')).to include("master's releases.yml lists sha256")
  end

  it 'defers signing steps while the key is locked' do
    world.update_scenario { it['signing'] = false }
    world.draft('9.9.1')
    out = watch
    expect(out).to include('import_draft deferred until signing is ready', 'unlock your signing key')
    expect(state).to include('state' => 'waiting_draft')

    world.update_scenario { it['signing'] = true }
    watch
    expect(state).to include('state' => 'drafted')
  end

  it 'defers on a dirty checkout and an unpushed commit on main, and resumes once cleaned' do
    world.draft('9.9.1')
    File.write(File.join(ruby, 'debian', 'source', 'format'), "3.0 (native)\n")
    out = watch
    expect(out).to include("commit or stash in #{ruby}")
    expect(state).to include('state' => 'waiting_draft')
    world.git(ruby, 'checkout', '--', '.')

    watch
    world.git(world.build_dir, 'commit', '-q', '--allow-empty', '-m', 'unrelated')
    out = watch
    expect(out).to include('push or drop your unpushed commits on main')
    expect(state).to include('state' => 'drafted')
    world.git(world.build_dir, 'reset', '-q', '--hard', 'HEAD~')

    watch
    expect(state).to include('state' => 'building')
  end

  it 'resumes from the refs after losing its state' do
    building
    FileUtils.rm_rf(File.join(world.build_dir, 'tmp', 'releng-watch'))
    expect(watch).to include('resuming as building from the refs')
    expect(state).to include('state' => 'building')

    world.publish('9.9.1')
    watch
    FileUtils.rm_rf(File.join(world.build_dir, 'tmp', 'releng-watch'))
    expect(watch).to include('resuming as finalized from the refs')
  end

  it 'only prints the pushes with --no-push' do
    world.draft('9.9.1')
    watch('--no-push')
    out = watch('--no-push')
    expect(out).to include('push it yourself (--no-push): bin/import --push --draft 9.9.1')
    expect(origin_rev('refs/heads/draft/master')).to be_nil
  end

  it 'prints the last poll with --status' do
    world.draft('9.9.1', tarball: world.tarball('9.9.1', greeting: 'hi'))
    watch
    status = world.bin('releng-watch', '--status')
    expect(status.output).to include('9.9.1: paused_patches', 'ACTION REQUIRED (1)')
  end
end
