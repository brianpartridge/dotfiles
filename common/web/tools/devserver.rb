#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Development server for the Transmission web UI in ../transmission.
#
# Serves the checkout the way Apache does in production, so edits show up on
# reload without deploying:
#
#   /transmission/         -> redirect to /transmission/web/
#   /transmission/web/     -> ../transmission (this checkout)
#   /transmission/rpc      -> proxied to a real Transmission (default localhost:9091)
#   /transfers/            -> the transfers dashboard directory, for transfers.json
#
# With --mock, the RPC and /transfers/transfers.json are served from built-in
# sample data instead, so the UI can be worked on without Transmission at all.
#
# Runs on the macOS system Ruby (2.3) with no gems: WEBrick is in its stdlib.
#
#   ruby common/web/tools/devserver.rb            # then open http://localhost:8080/transmission/
#   ruby common/web/tools/devserver.rb --mock
#   ruby common/web/tools/devserver.rb --rpc http://theater-mac.local:9091/transmission/rpc

require 'json'
require 'net/http'
require 'optparse'
require 'uri'
require 'webrick'

options = {
  port: 8080,
  rpc: 'http://127.0.0.1:9091/transmission/rpc',
  transfers: '/Library/WebServer/Documents/transfers',
  mock: false
}
OptionParser.new do |opts|
  opts.banner = 'Usage: devserver.rb [--port N] [--rpc URL] [--transfers DIR] [--mock]'
  opts.on('-p', '--port N', Integer, 'Listen port (default 8080)') { |v| options[:port] = v }
  opts.on('--rpc URL', 'Transmission RPC to proxy to') { |v| options[:rpc] = v }
  opts.on('--transfers DIR', 'Directory holding the dashboard and transfers.json') { |v| options[:transfers] = v }
  opts.on('--mock', 'Serve sample torrents and transfers instead of proxying') { options[:mock] = true }
  opts.on('-h', '--help') { puts opts; exit }
end.parse!

WEB_DIR = File.expand_path('../transmission', __dir__)

# ----------------------------------------------------------------------------
# Sample data for --mock: a few torrents in different states, and transfer
# records covering every badge the UI can show.
module Mock
  NOW = Time.now.to_i
  SESSION_ID = 'mock-session'

  def self.torrent(id, name, size, done, status, opts = {})
    have = (size * done).to_i
    {
      'id' => id, 'name' => name, 'hashString' => format('%040x', id), 'totalSize' => size, 'sizeWhenDone' => size,
      'leftUntilDone' => size - have, 'haveValid' => have, 'haveUnchecked' => 0, 'desiredAvailable' => size - have,
      'percentDone' => done, 'metadataPercentComplete' => 1, 'status' => status, 'isFinished' => false,
      'isStalled' => false, 'eta' => done >= 1 ? -1 : 1800, 'rateDownload' => opts[:down] || 0,
      'rateUpload' => opts[:up] || 0, 'uploadedEver' => (size * 0.6).to_i, 'downloadedEver' => have,
      'uploadRatio' => 0.6, 'corruptEver' => 0, 'error' => opts[:error] || 0, 'errorString' => opts[:error_string] || '',
      'queuePosition' => id, 'recheckProgress' => 0, 'peersConnected' => done >= 1 ? 3 : 12,
      'peersGettingFromUs' => 3, 'peersSendingToUs' => done >= 1 ? 0 : 8, 'webseedsSendingToUs' => 0,
      'seedRatioLimit' => 2, 'seedRatioMode' => 0, 'activityDate' => NOW - 60, 'addedDate' => NOW - (opts[:age] || 86_400),
      'startDate' => NOW - 86_000, 'dateCreated' => NOW - 500_000, 'doneDate' => done >= 1 ? NOW - (opts[:done_ago] || 3600) : 0,
      'downloadDir' => '/Users/theater/Transfers/3_complete', 'comment' => '', 'creator' => '', 'pieceCount' => 1000,
      'pieceSize' => size / 1000, 'isPrivate' => true,
      'files' => [{ 'name' => "#{name}.mkv", 'length' => size, 'bytesCompleted' => have }],
      'fileStats' => [{ 'bytesCompleted' => have, 'wanted' => true, 'priority' => 0 }],
      'trackers' => [{ 'id' => 1, 'announce' => 'https://tracker.example/announce', 'tier' => 0 }],
      'trackerStats' => [], 'peers' => []
    }
  end

  TORRENTS = [
    torrent(1, 'Some.Show.S03E07.720p.WEB.h264-GRP', 1_450_000_000, 1.0, 6, up: 120_000),
    torrent(2, 'Big.Movie.2023.2160p.WEB-DL-GRP', 12_000_000_000, 0.42, 4, down: 3_500_000, up: 40_000),
    torrent(3, 'Great.Film.2001.1080p.BluRay-GRP', 8_000_000_000, 1.0, 6, done_ago: 7200),
    torrent(4, 'Some.Show.S02.720p.HDTV-GRP', 6_000_000_000, 1.0, 6, done_ago: 86_400),
    torrent(5, 'Concert.Bootleg.FLAC-GRP', 900_000_000, 1.0, 6, done_ago: 5000),
    torrent(6, 'Quiet.Failure.S01E04.1080p.WEB-GRP', 2_100_000_000, 1.0, 6, done_ago: 9000),
    torrent(7, 'Other.Show.S01E01.1080p.WEB-GRP', 1_900_000_000, 1.0, 0, done_ago: 4000),
    torrent(8, 'Ancient.Thing.2010-GRP', 700_000_000, 1.0, 0, done_ago: 30 * 86_400, age: 31 * 86_400),
    torrent(9, 'Stalled.Thing.S02E01-GRP', 900_000_000, 0.0, 4, error: 3, error_string: 'No data found! Ensure your drives are connected')
  ].freeze

  def self.record(id, status, outcome, message, destination = nil)
    [format('%040x', id), { 'ts' => Time.at(NOW - 3600).iso8601, 'status' => status, 'outcome' => outcome,
                            'message' => message, 'destination' => destination }]
  end

  TRANSFERS = {
    'generated_at' => Time.now.iso8601, 'unhandled_window_days' => 7, 'dashboard_url' => '/transfers/',
    'by_hash' => [
      record(1, 'ok', 'tv', 'Linked Some.Show.S03E07.720p.WEB.h264-GRP.mkv into /Users/theater/Media/tv', '/Users/theater/Media/tv/Some.Show.S03E07.720p.WEB.h264-GRP.mkv'),
      record(3, 'ok', 'movie', 'Linked Great.Film.2001.1080p.BluRay-GRP.mkv into /Users/theater/Media/movies', '/Users/theater/Media/movies/Great.Film.2001.1080p.BluRay-GRP.mkv'),
      record(4, 'ok', 'tv', 'Linked 8 of 9 media files (tv) into /Users/theater/Media/tv; skipped: extras.mkv', '/Users/theater/Media/tv'),
      record(5, 'other', 'no_media', 'No media files among 14 files'),
      record(7, 'error', 'error', 'RuntimeError: Destination directory is missing (volume not mounted?): /Users/theater/Media/tv')
    ].to_h,
    'by_name' => {}
  }.freeze

  SESSION = {
    'alt-speed-enabled' => false, 'alt-speed-down' => 50, 'alt-speed-up' => 50, 'alt-speed-time-enabled' => false,
    'alt-speed-time-begin' => 540, 'alt-speed-time-end' => 1020, 'alt-speed-time-day' => 127,
    'blocklist-enabled' => false, 'blocklist-size' => 0, 'blocklist-url' => '', 'dht-enabled' => true,
    'download-dir' => '/Users/theater/Transfers/3_complete', 'download-dir-free-space' => 500_000_000_000,
    'download-queue-enabled' => true, 'download-queue-size' => 5, 'encryption' => 'preferred',
    'idle-seeding-limit' => 30, 'idle-seeding-limit-enabled' => false, 'incomplete-dir-enabled' => true,
    'incomplete-dir' => '/Users/theater/Transfers/2_incomplete', 'lpd-enabled' => false, 'peer-limit-global' => 200,
    'peer-limit-per-torrent' => 50, 'peer-port' => 51_413, 'peer-port-random-on-start' => false, 'pex-enabled' => true,
    'port-forwarding-enabled' => true, 'queue-stalled-enabled' => true, 'queue-stalled-minutes' => 30,
    'rename-partial-files' => true, 'rpc-version' => 15, 'rpc-version-minimum' => 1, 'seed-queue-enabled' => false,
    'seed-queue-size' => 10, 'seedRatioLimit' => 2, 'seedRatioLimited' => false, 'speed-limit-down' => 100,
    'speed-limit-down-enabled' => false, 'speed-limit-up' => 100, 'speed-limit-up-enabled' => false,
    'start-added-torrents' => true, 'trash-original-torrent-files' => false, 'utp-enabled' => true,
    'units' => { 'memory-bytes' => 1024, 'memory-units' => %w[KiB MiB GiB TiB], 'size-bytes' => 1000,
                 'size-units' => %w[kB MB GB TB], 'speed-bytes' => 1000, 'speed-units' => %w[kB/s MB/s GB/s TB/s] },
    'version' => '2.93 (mock)'
  }.freeze

  STATS = {
    'activeTorrentCount' => 2, 'downloadSpeed' => 3_500_000, 'pausedTorrentCount' => 2, 'torrentCount' => TORRENTS.count,
    'uploadSpeed' => 160_000,
    'cumulative-stats' => { 'uploadedBytes' => 9e11.to_i, 'downloadedBytes' => 1.2e12.to_i, 'filesAdded' => 2000, 'secondsActive' => 90_000_000, 'sessionCount' => 300 },
    'current-stats' => { 'uploadedBytes' => 2e9.to_i, 'downloadedBytes' => 5e9.to_i, 'filesAdded' => 4, 'secondsActive' => 90_000, 'sessionCount' => 1 }
  }.freeze

  def self.rpc(request)
    body = JSON.parse(request.body.to_s) rescue {}
    args = body['arguments'] || {}
    result = case body['method']
             when 'session-get' then SESSION
             when 'session-stats' then STATS
             when 'port-test' then { 'port-is-open' => true }
             when 'torrent-get'
               ids = args['ids']
               fields = args['fields'] || []
               selected = TORRENTS.select { |t| ids.nil? || ids == 'recently-active' || Array(ids).include?(t['id']) }
               out = { 'torrents' => selected.map { |t| fields.map { |f| [f, t.fetch(f, 0)] }.to_h } }
               out['removed'] = [] if ids == 'recently-active'
               out
             else {}
             end
    JSON.generate('result' => 'success', 'arguments' => result)
  end
end

# ----------------------------------------------------------------------------
server = WEBrick::HTTPServer.new(Port: options[:port], BindAddress: '0.0.0.0',
                                 AccessLog: [[$stdout, '%m %U -> %s']], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN))

server.mount_proc('/transmission') do |req, res|
  raise WEBrick::HTTPStatus::NotFound unless ['/transmission', '/transmission/'].include?(req.path)

  res.set_redirect(WEBrick::HTTPStatus::MovedPermanently, '/transmission/web/')
end

server.mount('/transmission/web', WEBrick::HTTPServlet::FileHandler, WEB_DIR, FancyIndexing: false)

rpc_uri = URI(options[:rpc])
server.mount_proc('/transmission/rpc') do |req, res|
  if options[:mock]
    if req['X-Transmission-Session-Id'] != Mock::SESSION_ID
      res.status = 409
      res['X-Transmission-Session-Id'] = Mock::SESSION_ID
    else
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = Mock.rpc(req)
    end
  else
    # Same as Apache's ProxyPass: forward the body and the session header both ways.
    http = Net::HTTP.new(rpc_uri.host, rpc_uri.port)
    http.use_ssl = rpc_uri.scheme == 'https'
    upstream = Net::HTTP::Post.new(rpc_uri.path)
    upstream['Content-Type'] = 'application/json'
    upstream['X-Transmission-Session-Id'] = req['X-Transmission-Session-Id'] if req['X-Transmission-Session-Id']
    upstream.body = req.body
    begin
      answer = http.request(upstream)
      res.status = answer.code.to_i
      res['X-Transmission-Session-Id'] = answer['X-Transmission-Session-Id'] if answer['X-Transmission-Session-Id']
      res['Content-Type'] = answer['Content-Type'] || 'application/json'
      res.body = answer.body.to_s
    rescue StandardError => e
      res.status = 503
      res['Content-Type'] = 'text/plain'
      res.body = "Cannot reach Transmission at #{options[:rpc]}: #{e.class}: #{e.message}\n"
    end
  end
end

if options[:mock]
  server.mount_proc('/transfers/transfers.json') do |_req, res|
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(Mock::TRANSFERS)
  end
  server.mount_proc('/transfers') do |_req, res|
    res['Content-Type'] = 'text/plain'
    res.body = "Mock mode: the transfers dashboard is not served here, only transfers.json.\n"
  end
else
  server.mount('/transfers', WEBrick::HTTPServlet::FileHandler, options[:transfers], FancyIndexing: false)
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
puts "Serving #{WEB_DIR}"
puts "  http://localhost:#{options[:port]}/transmission/"
puts(options[:mock] ? '  RPC and transfers.json: built-in mock data' : "  RPC -> #{options[:rpc]}, transfers -> #{options[:transfers]}")
server.start
