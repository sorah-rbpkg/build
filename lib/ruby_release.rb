# Shared by bin/import and bin/verify-orig.
require 'date'
require 'digest'
require 'json'
require 'net/http'
require 'yaml'

module RubyRelease
  # Releases and their checksums are kept here, apart from the server that hosts the tarballs.
  WWW_REPOSITORY = 'ruby/www.ruby-lang.org'
  DRAFT_URL = 'https://cache.ruby-lang.org/pub/tmp/'

  def self.fetch(url)
    res = Net::HTTP.get_response(URI(url))
    raise "GET #{url}: #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    res.body
  end

  def self.releases_url(ref) = "https://raw.githubusercontent.com/#{WWW_REPOSITORY}/#{ref}/_data/releases.yml"

  # releases.yml of master, preceded by that of each pull request for a release not announced yet.
  Index = Data.define(:sources) do
    def self.load(prs: [])
      urls = prs.map do |number|
        pr = JSON.parse(RubyRelease.fetch("https://api.github.com/repos/#{WWW_REPOSITORY}/pulls/#{number}"))
        head = pr.fetch('head')
        # Only a branch of the repository itself, so a fork cannot supply checksums.
        raise "#{WWW_REPOSITORY}##{number} comes from a fork" unless head.fetch('repo')&.fetch('full_name') == WWW_REPOSITORY

        warn "#{WWW_REPOSITORY}##{number} by #{pr.fetch('user').fetch('login')} at #{head.fetch('sha')}: #{pr.fetch('title')}"
        RubyRelease.releases_url(head.fetch('sha'))
      end
      new(sources: [*urls, RubyRelease.releases_url('master')].to_h { [it, YAML.safe_load(RubyRelease.fetch(it), permitted_classes: [Date])] })
    end

    def find(version)
      sources.each_value.lazy.filter_map { |rs| rs.find { it.fetch('version') == version } }.first or
        raise "ruby #{version} is in none of #{sources.keys.join(' ')}"
    end
  end

  # Saves the .tar.gz of release to path, checked against its sha256, and returns where it came from.
  def self.download(release, path)
    url = release.fetch('url').fetch('gz')
    res = Net::HTTP.get_response(URI(url))
    case res
    when Net::HTTPSuccess
      File.binwrite(path, res.body)
    when Net::HTTPNotFound
      # Until the release is announced, its tarball is a draft in pub/tmp/.
      url = "#{DRAFT_URL}#{File.basename(url, '.tar.gz')}-draft.tar.gz"
      warn "#{release.fetch('url').fetch('gz')} is not there yet; taking #{url}"
      File.binwrite(path, fetch(url))
    else
      raise "GET #{url}: #{res.code}"
    end
    sha256 = Digest::SHA256.file(path).hexdigest
    expected = release.fetch('sha256').fetch('gz')
    raise "#{url}: sha256 is #{sha256}, not #{expected}" unless sha256 == expected
    url
  end
end
