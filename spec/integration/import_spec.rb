require 'json'

RSpec.describe 'bin/import' do
  let(:world) { World.create }
  let(:ruby) { world.ruby_dir }

  after { world.cleanup }

  def import(*args, input: nil) = world.bin('import', *args, input:)
  def origin_rev(ref) = world.rev(world.origin('sorah-rbpkg/ruby'), ref)
  def checksum(version) = JSON.parse(File.read(File.join(world.build_dir, 'checksums', "ruby-#{version}.json")))

  def expect_success(result)
    expect(result).to be_success, result.output
    result
  end

  def expect_failure(result, message)
    expect(result).not_to be_success, result.output
    expect(result.output).to include(message)
    result
  end

  def drafted(version = '9.9.1', **)
    world.draft(version, **)
    expect_success(import('--draft', version))
    expect_success(import('--push', '--draft', '--yes', version))
  end

  describe '--draft' do
    it 'imports onto draft branches with the draft checksum and no pristine-tar data' do
      master = origin_rev('refs/heads/master')
      pristine_tar = origin_rev('refs/heads/pristine-tar')
      world.draft('9.9.1')

      expect_success(import('--draft', '9.9.1'))

      expect(world.git(ruby, 'show', 'draft/master:debian/changelog').lines.first).to start_with('ruby9.9 (9.9.1-0nkmi1~dist)')
      expect(world.git(ruby, 'merge-base', '--is-ancestor', master, 'draft/master')).to eq('')
      expect(world.git(ruby, 'show', 'draft/upstream-9.9:version.h')).to include('9.9.1')
      expect(world.run('git', 'verify-tag', 'upstream/9.9.1', chdir: ruby)).to be_success
      expect(world.rev(ruby, 'refs/heads/pristine-tar')).to be_nil.or eq(pristine_tar)
      expect(world.rev(ruby, 'refs/heads/master')).to eq(master)
      expect(checksum('9.9.1')).to include('source' => 'draft', 'sha256' => Digest::SHA256.file(world.tarball('9.9.1')).hexdigest)
    end

    it 'refuses a version without a draft' do
      expect_failure(import('--draft', '9.9.1'), '9.9.1 has no draft')
    end

    it 'skips a version already imported from the same draft' do
      world.draft('9.9.1')
      expect_success(import('--draft', '9.9.1'))
      head = world.rev(ruby, 'refs/heads/draft/master')

      result = expect_success(import('--draft', '9.9.1'))

      expect(result.output).to include('imported from its draft already')
      expect(world.rev(ruby, 'refs/heads/draft/master')).to eq(head)
    end

    it 'refuses a re-cut draft until the old one is discarded' do
      drafted
      world.draft('9.9.1', tarball: world.tarball('9.9.1', cut: 2))
      expect_failure(import('--draft', '9.9.1'), 'bin/import --discard 9.9.1 first')
    end

    it 'warns but completes when debian/patches does not apply' do
      world.draft('9.9.1', tarball: world.tarball('9.9.1', greeting: 'hi'))
      result = expect_success(import('--draft', '9.9.1'))
      expect(result.output).to include('debian/patches fails to apply')
    end
  end

  describe '--push --draft' do
    it 'pushes only the draft branches and the tag' do
      master = origin_rev('refs/heads/master')
      drafted
      expect(origin_rev('refs/heads/draft/master')).to eq(world.rev(ruby, 'refs/heads/draft/master'))
      expect(origin_rev('refs/heads/draft/upstream-9.9')).to eq(world.rev(ruby, 'refs/heads/draft/upstream-9.9'))
      expect(origin_rev('refs/tags/upstream/9.9.1')).not_to be_nil
      expect(origin_rev('refs/heads/master')).to eq(master)
    end

    it 'asks before pushing without --yes' do
      world.draft('9.9.1')
      expect_success(import('--draft', '9.9.1'))
      expect_failure(import('--push', '--draft', '9.9.1', input: "n\n"), 'Not pushed')
      expect(origin_rev('refs/heads/draft/master')).to be_nil
    end
  end

  describe '--discard' do
    it 'deletes the draft branches and tag on origin and locally, so a re-cut can be imported' do
      drafted
      expect_success(import('--discard', '--yes', '9.9.1'))

      expect(origin_rev('refs/heads/draft/master')).to be_nil
      expect(origin_rev('refs/heads/draft/upstream-9.9')).to be_nil
      expect(origin_rev('refs/tags/upstream/9.9.1')).to be_nil
      expect(world.rev(ruby, 'refs/heads/draft/master')).to be_nil
      expect(world.rev(ruby, 'refs/tags/upstream/9.9.1')).to be_nil

      recut = world.tarball('9.9.1', cut: 2)
      world.draft('9.9.1', tarball: recut)
      expect_success(import('--draft', '9.9.1'))
      expect(checksum('9.9.1').fetch('sha256')).to eq(Digest::SHA256.file(recut).hexdigest)
    end

    it 'cleans up a draft that was never pushed' do
      world.draft('9.9.1')
      expect_success(import('--draft', '9.9.1'))
      expect_success(import('--discard', '--yes', '9.9.1'))
      expect(world.rev(ruby, 'refs/heads/draft/master')).to be_nil
    end

    it 'refuses a finalized release' do
      drafted
      world.publish('9.9.1')
      expect_success(import('--finalize', '--yes', '9.9.1'))
      expect_failure(import('--discard', '--yes', '9.9.1'), 'is not a draft')
      expect(origin_rev('refs/tags/upstream/9.9.1')).not_to be_nil
    end
  end

  describe '--finalize' do
    it 'fast-forwards the real branches, commits pristine-tar data and deletes the draft branches' do
      drafted
      draft_master = origin_rev('refs/heads/draft/master')
      draft_upstream = origin_rev('refs/heads/draft/upstream-9.9')
      world.publish('9.9.1')

      expect_success(import('--finalize', '--yes', '9.9.1'))

      expect(origin_rev('refs/heads/master')).to eq(draft_master)
      expect(origin_rev('refs/heads/upstream-9.9')).to eq(draft_upstream)
      expect(origin_rev('refs/heads/draft/master')).to be_nil
      expect(origin_rev('refs/heads/draft/upstream-9.9')).to be_nil
      expect(world.git(ruby, 'ls-tree', '--name-only', 'refs/remotes/origin/pristine-tar')).to include('ruby9.9_9.9.1.orig.tar.gz.delta')
      expect(world.rev(ruby, 'refs/heads/master')).to eq(draft_master)
      expect(world.rev(ruby, 'refs/heads/draft/master')).to be_nil

      out = world.path('ruby9.9_9.9.1.orig.tar.gz')
      world.sh('pristine-tar', 'checkout', out, chdir: ruby)
      expect(Digest::SHA256.file(out).hexdigest).to eq(Digest::SHA256.file(world.tarball('9.9.1')).hexdigest)
    end

    it 'is a no-op once finalized' do
      drafted
      world.publish('9.9.1')
      expect_success(import('--finalize', '--yes', '9.9.1'))
      expect(expect_success(import('--finalize', '--yes', '9.9.1')).output).to include('finalized already')
    end

    it 'refuses before the release is published' do
      drafted
      expect_failure(import('--finalize', '--yes', '9.9.1'), 'GET https://cache.ruby-lang.org/pub/ruby/9.9/ruby-9.9.1.tar.gz: 404')
      expect(origin_rev('refs/heads/draft/master')).not_to be_nil
    end

    it 'refuses a published tarball that differs from the committed checksum' do
      drafted
      world.publish('9.9.1', tarball: world.tarball('9.9.1', greeting: 'hi'))
      expect_failure(import('--finalize', '--yes', '9.9.1'), 'from draft')
      expect(origin_rev('refs/heads/draft/master')).not_to be_nil
    end

    it 'refuses when the real branch moved past the draft' do
      drafted
      world.publish('9.9.1')
      other = world.path('other')
      world.sh('git', 'clone', '-q', "file://#{world.origin('sorah-rbpkg/ruby')}", other)
      world.sh('git', 'commit', '-q', '--allow-empty', '-m', 'moved', chdir: other)
      world.sh('git', 'push', '-q', 'origin', 'master', chdir: other)

      expect_failure(import('--finalize', '--yes', '9.9.1'), 'git rebase origin/master draft/master')
      expect(origin_rev('refs/heads/draft/master')).not_to be_nil
    end
  end

  describe 'without --draft' do
    it 'imports an announced release onto the real branches with its checksum from master' do
      world.announce('9.9.1')
      world.publish('9.9.1')
      expect_success(import('9.9.1'))
      expect(world.git(ruby, 'show', 'master:debian/changelog').lines.first).to start_with('ruby9.9 (9.9.1-0nkmi1~dist)')
      expect(checksum('9.9.1')).to include('source' => 'ruby/www.ruby-lang.org@master')
    end

    it 'writes only the checksum with --checksum-only' do
      world.announce('9.9.1')
      expect_success(import('--checksum-only', '9.9.1'))
      expect(checksum('9.9.1')).to include('version' => '9.9.1')
      expect(world.rev(ruby, 'refs/tags/upstream/9.9.1')).to be_nil
    end
  end

  describe 'then bin/roll' do
    def roll(*args) = world.bin('roll', *args)
    def series = JSON.parse(File.read(File.join(world.build_dir, 'gen', 'builds', 'ruby9.9.json')))

    it 'rolls draft/master with its checksum, which bin/plan accepts' do
      drafted
      expect_success(roll('draft/master'))

      expect(series.fetch('commit')).to eq(origin_rev('refs/heads/draft/master'))
      expect(world.git(world.build_dir, 'show', '--name-only', '--format=%s', 'HEAD').lines(chomp: true))
        .to include('roll ruby9.9 9.9.1-0nkmi1', 'checksums/ruby-9.9.1.json', 'gen/builds/ruby9.9.json')
      targets = JSON.parse(expect_success(world.bin('plan', 'gen/builds/ruby9.9.json')).output.lines.last).fetch('targets')
      expect(targets.map { it.fetch('distro') }).to eq(['trixie'])
    end

    it 'refuses a non-native roll without a checksum' do
      drafted
      File.delete(File.join(world.build_dir, 'checksums', 'ruby-9.9.1.json'))
      expect_failure(roll('draft/master'), 'bin/import --checksum-only 9.9.1')
    end

    it 'makes bin/plan refuse a draft commit whose checksum is not from a draft' do
      drafted
      expect_success(roll('draft/master'))
      path = File.join(world.build_dir, 'checksums', 'ruby-9.9.1.json')
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('source' => 'ruby/www.ruby-lang.org@master')))
      expect_failure(world.bin('plan', 'gen/builds/ruby9.9.json'), 'is only on draft/master, but its checksum is not from a draft')
    end
  end

  describe 'then bin/check-patches' do
    it 'reports the patch that does not apply' do
      world.draft('9.9.1', tarball: world.tarball('9.9.1', greeting: 'hi'))
      expect_success(import('--draft', '9.9.1'))
      expect_failure(world.bin('check-patches', 'draft/master'), 'greeting.patch')
    end
  end
end
