require 'digest'
require 'tmpdir'
require_relative '../../lib/ruby_release'

RSpec.describe RubyRelease do
  let(:external) { instance_double(Releng::External) }
  let(:body) { 'tarball bytes' }
  let(:sha256) { Digest::SHA256.hexdigest(body) }
  let(:entry) do
    {'version' => '9.9.1', 'url' => {'gz' => 'https://cache.ruby-lang.org/pub/ruby/9.9/ruby-9.9.1.tar.gz'}, 'sha256' => {'gz' => sha256}}
  end

  before do
    allow(Releng::External).to receive(:current).and_return(external)
    allow(external).to receive(:http_get) { |url| raise "unexpected GET #{url}" }
  end

  def response(status, body = '') = Releng::External::Response.new(status:, body:)
  def serve(url, status, body = '') = allow(external).to receive(:http_get).with(url).and_return(response(status, body))

  describe '.draft_info' do
    let(:url) { 'https://cache.ruby-lang.org/pub/tmp/ruby-info-9.9.1-draft.yml' }

    it 'returns the entry of the version' do
      serve(url, 200, YAML.dump([entry]))
      expect(described_class.draft_info('9.9.1')).to eq(entry)
    end

    it 'is nil while there is no draft, which the bucket answers with 403 or 404' do
      serve(url, 403)
      expect(described_class.draft_info('9.9.1')).to be_nil
      serve(url, 404)
      expect(described_class.draft_info('9.9.1')).to be_nil
    end

    it 'raises on other errors' do
      serve(url, 500)
      expect { described_class.draft_info('9.9.1') }.to raise_error(/500/)
    end
  end

  describe RubyRelease::Index do
    let(:master) { RubyRelease.releases_url('master') }

    it 'finds the version in master' do
      serve(master, 200, YAML.dump([entry]))
      checksum = described_class.load.find('9.9.1')
      expect(checksum).to have_attributes(sha256:, url: entry.dig('url', 'gz'), source: 'ruby/www.ruby-lang.org@master')
    end

    it 'prefers a pull request over master, pinned to its head' do
      allow(external).to receive(:github).with('repos/ruby/www.ruby-lang.org/pulls/42').and_return(
        'head' => {'sha' => 'abc', 'repo' => {'full_name' => 'ruby/www.ruby-lang.org'}}, 'user' => {'login' => 'matzbot'}, 'title' => 't',
      )
      serve(RubyRelease.releases_url('abc'), 200, YAML.dump([entry]))
      serve(master, 200, YAML.dump([entry.merge('sha256' => {'gz' => 'other'})]))
      expect { expect(described_class.load(prs: [42]).find('9.9.1').source).to eq('ruby/www.ruby-lang.org#42@abc') }
        .to output(/matzbot/).to_stderr
    end

    it 'refuses a pull request from a fork' do
      allow(external).to receive(:github).and_return('head' => {'sha' => 'abc', 'repo' => {'full_name' => 'someone/www.ruby-lang.org'}})
      expect { described_class.load(prs: [42]) }.to raise_error(/comes from a fork/)
    end

    it 'falls back to drafts after master' do
      serve(master, 200, YAML.dump([]))
      serve('https://cache.ruby-lang.org/pub/tmp/ruby-info-9.9.1-draft.yml', 200, YAML.dump([entry]))
      expect(described_class.load(drafts: ['9.9.1']).find('9.9.1').source).to eq('draft')
    end

    it 'names every source when the version is in none' do
      serve(master, 200, YAML.dump([]))
      expect { described_class.load.find('9.9.1') }.to raise_error('ruby 9.9.1 is in none of ruby/www.ruby-lang.org@master')
    end
  end

  describe RubyRelease::Checksum do
    let(:dir) { Dir.mktmpdir }

    before { stub_const('RubyRelease::CHECKSUMS_DIR', File.join(dir, 'checksums')) }
    after { FileUtils.rm_rf(dir) }

    it 'round-trips through checksums/' do
      checksum = described_class.from_release(entry, source: 'draft')
      checksum.write
      expect(described_class.read('9.9.1')).to eq(checksum)
    end

    it 'reads nil for a version without one' do
      expect(described_class.read('9.9.1')).to be_nil
    end
  end

  describe '.download' do
    let(:checksum) { RubyRelease::Checksum.from_release(entry, source: 'draft') }
    let(:draft_url) { 'https://cache.ruby-lang.org/pub/tmp/ruby-9.9.1-draft.tar.gz' }

    around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, 'ruby.tar.gz') and example.run } }

    it 'takes the published tarball' do
      serve(checksum.url, 200, body)
      expect(described_class.download(checksum, @path)).to eq(checksum.url)
      expect(File.binread(@path)).to eq(body)
    end

    it 'falls back to the draft until published' do
      serve(checksum.url, 404)
      serve(draft_url, 200, body)
      expect { expect(described_class.download(checksum, @path)).to eq(draft_url) }.to output(/not there yet/).to_stderr
    end

    it 'does not fall back with published_only' do
      serve(checksum.url, 404)
      expect { described_class.download(checksum, @path, published_only: true) }.to raise_error(/404/)
    end

    it 'refuses a tarball whose sha256 differs, naming the checksum source' do
      serve(checksum.url, 200, 'other bytes')
      expect { described_class.download(checksum, @path) }.to raise_error(/not #{sha256} from draft/)
    end
  end
end
