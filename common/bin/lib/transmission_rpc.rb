# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# Minimal client for Transmission's RPC interface.
# https://github.com/transmission/transmission/blob/main/docs/rpc-spec.md
#
# Enable it in Transmission.app under Preferences > Remote > "Enable remote
# access". The default endpoint is http://localhost:9091/transmission/rpc.
# If you require authentication or use another port, put the details in
# ~/Dropbox/conf/transmission.json:
#
#   { "url": "http://localhost:9091/transmission/rpc",
#     "username": "...", "password": "..." }
class TransmissionRPC
  DEFAULT_URL = 'http://localhost:9091/transmission/rpc'
  DEFAULT_CONFIG = '~/Dropbox/conf/transmission.json'
  SESSION_HEADER = 'X-Transmission-Session-Id'
  TORRENT_FIELDS = %w[id name hashString percentDone isFinished status doneDate addedDate
                      downloadDir totalSize error errorString].freeze
  STATUS_NAMES = {
    0 => 'stopped', 1 => 'check pending', 2 => 'checking', 3 => 'download pending',
    4 => 'downloading', 5 => 'seed pending', 6 => 'seeding'
  }.freeze

  class Error < StandardError; end

  def self.from_config(path = nil)
    path = File.expand_path(path || ENV['TRANSMISSION_CONFIG'] || DEFAULT_CONFIG)
    conf = File.file?(path) ? JSON.parse(File.read(path)) : {}
    new(url: conf['url'] || ENV['TRANSMISSION_RPC_URL'] || DEFAULT_URL,
        username: conf['username'], password: conf['password'])
  end

  def self.status_name(code)
    STATUS_NAMES.fetch(code.to_i, "status #{code}")
  end

  attr_reader :uri

  def initialize(url: DEFAULT_URL, username: nil, password: nil, timeout: 5)
    @uri = URI(url)
    @username = username
    @password = password
    @timeout = timeout
    @session_id = nil
  end

  # All torrents Transmission knows about, with TORRENT_FIELDS.
  def torrents
    call('torrent-get', 'fields' => TORRENT_FIELDS).fetch('torrents', [])
  end

  # Raises TransmissionRPC::Error for any transport or protocol failure.
  def call(method, arguments = {})
    body = JSON.generate('method' => method, 'arguments' => arguments)
    response = post(body)
    if response.code == '409'
      @session_id = response[SESSION_HEADER]
      response = post(body)
    end
    raise Error, "HTTP #{response.code} from #{@uri}" unless response.code == '200'

    payload = JSON.parse(response.body)
    raise Error, "#{method} failed: #{payload['result']}" unless payload['result'] == 'success'

    payload.fetch('arguments', {})
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "#{e.class}: #{e.message} (#{@uri})"
  end

  private

  def post(body)
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = @uri.scheme == 'https'
    http.open_timeout = @timeout
    http.read_timeout = @timeout
    request = Net::HTTP::Post.new(@uri.path)
    request['Content-Type'] = 'application/json'
    request[SESSION_HEADER] = @session_id if @session_id
    request.basic_auth(@username, @password) if @username
    request.body = body
    http.request(request)
  end
end
