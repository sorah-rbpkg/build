# Shared by bin/import, bin/plan, bin/roll and bin/verify-orig.
require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'yaml'
require_relative 'releng/external'

module RubyRelease
  # Releases and their checksums are kept here, apart from the server that hosts the tarballs.
  WWW_REPOSITORY = 'ruby/www.ruby-lang.org'
  DRAFT_URL = 'https://cache.ruby-lang.org/pub/tmp/'
  CHECKSUMS_DIR = File.expand_path('../checksums', __dir__)

  def self.get(url) = Releng::External.current.http_get(url)

  def self.fetch(url)
    res = get(url)
    raise Releng::External::Error, "GET #{url}: #{res.status}" unless res.ok?
    res.body
  end

  def self.releases_url(ref) = "https://raw.githubusercontent.com/#{WWW_REPOSITORY}/#{ref}/_data/releases.yml"
  def self.draft_info_url(version) = "#{DRAFT_URL}ruby-info-#{version}-draft.yml"

  def self.load_releases(body) = YAML.safe_load(body, permitted_classes: [Date])

  # The releases.yml entry draft-release.yml leaves next to a draft, or nil while there is none.
  def self.draft_info(version)
    url = draft_info_url(version)
    res = get(url)
    case res.status
    when 200 then load_releases(res.body).find { it.fetch('version') == version }
    # The bucket answers 403 for a missing object.
    when 403, 404 then nil
    else raise Releng::External::Error, "GET #{url}: #{res.status}"
    end
  end

  # The gz tarball of a release and the checksum this repository trusts for it, kept in checksums/.
  Checksum = Data.define(:version, :url, :sha256, :source) do
    def self.from_release(entry, source:)
      new(version: entry.fetch('version'), url: entry.fetch('url').fetch('gz'), sha256: entry.fetch('sha256').fetch('gz'), source:)
    end

    def self.path(version) = File.join(CHECKSUMS_DIR, "ruby-#{version}.json")

    def self.read(version)
      path = path(version)
      new(**JSON.parse(File.read(path), symbolize_names: true)) if File.exist?(path)
    end

    def path = self.class.path(version)
    def write
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(to_h)}\n")
    end
  end

  # releases.yml of master, preceded by that of each pull request and followed by each draft's entry.
  Index = Data.define(:sources) do
    def self.load(prs: [], drafts: [])
      sources = prs.to_h do |number|
        pr = Releng::External.current.github("repos/#{WWW_REPOSITORY}/pulls/#{number}")
        head = pr.fetch('head')
        # Only a branch of the repository itself, so a fork cannot supply checksums.
        raise "#{WWW_REPOSITORY}##{number} comes from a fork" unless head.fetch('repo')&.fetch('full_name') == WWW_REPOSITORY

        warn "#{WWW_REPOSITORY}##{number} by #{pr.fetch('user').fetch('login')} at #{head.fetch('sha')}: #{pr.fetch('title')}"
        ["#{WWW_REPOSITORY}##{number}@#{head.fetch('sha')}", RubyRelease.load_releases(RubyRelease.fetch(RubyRelease.releases_url(head.fetch('sha'))))]
      end
      sources["#{WWW_REPOSITORY}@master"] = RubyRelease.load_releases(RubyRelease.fetch(RubyRelease.releases_url('master')))
      sources['draft'] = drafts.filter_map { RubyRelease.draft_info(it) } unless drafts.empty?
      new(sources:)
    end

    def find(version)
      sources.each do |source, entries|
        entry = entries.find { it.fetch('version') == version }
        return Checksum.from_release(entry, source:) if entry
      end
      raise "ruby #{version} is in none of #{sources.keys.join(', ')}"
    end
  end

  # Saves the tarball of checksum to path, checked against its sha256, and returns where it came from.
  # Until the release is announced, its tarball is a draft in pub/tmp/, unless published_only.
  def self.download(checksum, path, published_only: false)
    url = checksum.url
    res = get(url)
    case res.status
    when 200
      File.binwrite(path, res.body)
    when 403, 404
      raise "GET #{url}: #{res.status}" if published_only

      url = "#{DRAFT_URL}#{File.basename(url, '.tar.gz')}-draft.tar.gz"
      warn "#{checksum.url} is not there yet; taking #{url}"
      File.binwrite(path, fetch(url))
    else
      raise "GET #{url}: #{res.status}"
    end
    sha256 = Digest::SHA256.file(path).hexdigest
    raise "#{url}: sha256 is #{sha256}, not #{checksum.sha256} from #{checksum.source}" unless sha256 == checksum.sha256
    url
  end
end
