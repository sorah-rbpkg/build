# Every call bin/releng-watch and the scripts it runs make outside this machine, except git, whose remotes
# RELENG_GITHUB_URL can point elsewhere. RELENG_FAKE_EXTERNAL names a scenario file that answers them instead.
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'timeout'

module Releng
  def self.github_url(repository) = "#{ENV.fetch('RELENG_GITHUB_URL', 'https://github.com/')}#{repository}.git"

  class External
    # A call that failed, as the network or the other side may at any time.
    class Error < StandardError; end

    NETWORK_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

    Response = Data.define(:status, :body) do
      def ok? = (200..299).cover?(status)
    end

    def self.current
      @current ||= ENV['RELENG_FAKE_EXTERNAL'] ? FakeExternal.new(ENV.fetch('RELENG_FAKE_EXTERNAL')) : new
    end

    def http_get(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { it.request(Net::HTTP::Get.new(uri)) }
      Response.new(status: res.code.to_i, body: res.body)
    rescue *NETWORK_ERRORS => e
      raise Error, "GET #{url} failed", cause: e
    end

    def http_head(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { it.request(Net::HTTP::Head.new(uri)) }
      res.code.to_i
    rescue *NETWORK_ERRORS => e
      raise Error, "HEAD #{url} failed", cause: e
    end

    # The GitHub REST API through gh, which holds the credentials.
    def github(path, method: 'GET', fields: {})
      args = ['gh', 'api', '--method', method, path]
      fields.each do |k, v|
        if v.is_a?(Array)
          v.each { args.push('-F', "#{k}[]=#{it}") }
        else
          args.push('-f', "#{k}=#{v}")
        end
      end
      out, err, status = Open3.capture3(*args)
      raise Error, "gh api #{method} #{path}: #{err.strip}" unless status.success?
      out.empty? ? nil : JSON.parse(out)
    end

    # Whether git in dir can sign now, without prompting for a passphrase.
    def signing_ok?(dir)
      program = git_config(dir, 'gpg.program') || 'gpg'
      key = git_config(dir, 'user.signingkey')
      _, status = Open3.capture2e(program, '--batch', '--pinentry-mode', 'error', *(['--local-user', key] if key),
        '--sign', '-o', File::NULL, stdin_data: '')
      status.success?
    end

    private def git_config(dir, key)
      out, status = Open3.capture2('git', '-C', dir, 'config', key)
      out.strip if status.success?
    end
  end

  # Answers from a JSON scenario re-read on every call, so a test advances it by rewriting the file:
  #   {"http": {URL: {"status": 200, "body": "...", "body_file": PATH}}, "github": {"GET PATH": JSON},
  #    "signing": true}
  # A URL missing from "http" answers 404. Calls other than GET are appended to "<scenario>.calls.jsonl".
  class FakeExternal
    def initialize(path)
      @path = path
    end

    def scenario = JSON.parse(File.read(@path))

    def http_get(url)
      entry = scenario.fetch('http', {})[url] or return External::Response.new(status: 404, body: '')
      body = entry['body_file'] ? File.binread(entry.fetch('body_file')) : entry.fetch('body', '')
      External::Response.new(status: entry.fetch('status', 200), body:)
    end

    def http_head(url) = http_get(url).status

    def github(path, method: 'GET', fields: {})
      unless method == 'GET'
        File.open("#{@path}.calls.jsonl", 'a') { it.puts(JSON.generate({method:, path:, fields:})) }
      end
      responses = scenario.fetch('github', {})
      return responses["#{method} #{path}"] if responses.key?("#{method} #{path}")
      raise External::Error, "gh api #{method} #{path}: HTTP 404: Not Found" if method == 'GET'
    end

    def signing_ok?(_dir) = scenario.fetch('signing', true)
  end
end
