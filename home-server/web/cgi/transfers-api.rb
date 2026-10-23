#!/usr/bin/ruby
# frozen_string_literal: true
#
# The dashboard's one write endpoint: queues a job for transfers-worker.rb.
# Deployed by transmission-web-deploy.sh to /Library/WebServer/CGI-Executables
# and reached as /transfers/api (see home-server/conf/apache/transmission.conf).
#
# Runs as Apache's _www user with the system Ruby, so it is self-contained:
# it validates the request and writes one small JSON file into the queue
# directory, which must be world-writable (chmod 1777). Everything else
# happens in the worker, as the real user.
#
#   POST /transfers/api
#   X-Requested-With: transfers          (browsers will not send this cross-site)
#   {"action":"promote","hash":"<40 hex>","keep_link":false}
#   {"action":"promote","path":"/Users/theater/Media/tv/X.mkv"}
#   {"action":"remove_torrent","hash":"<40 hex>","keep_library":true}
#   {"action":"unlink_library","hash":"<40 hex>"}  or  {"action":"unlink_library","path":"..."}
#   {"action":"rerun_finish","hash":"<40 hex>"}

require 'json'

QUEUE = ENV['TRANSFERS_QUEUE'] || '/Users/theater/logs/transfers-queue'
MEDIA_ROOT = ENV['MEDIA_ROOT'] || '/Users/theater/Media'
# action => which of hash / path it accepts
ACTIONS = { 'promote' => %w[hash path], 'remove_torrent' => %w[hash], 'unlink_library' => %w[hash path],
            'rerun_finish' => %w[hash] }.freeze

def respond(status, body)
  print "Status: #{status}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n"
  print JSON.generate(body)
  exit
end

respond('405 Method Not Allowed', 'error' => 'POST only') unless ENV['REQUEST_METHOD'] == 'POST'
respond('403 Forbidden', 'error' => 'missing X-Requested-With: transfers') unless ENV['HTTP_X_REQUESTED_WITH'] == 'transfers'

length = ENV['CONTENT_LENGTH'].to_i
respond('400 Bad Request', 'error' => 'empty or oversized body') if length <= 0 || length > 4096
request = begin
  JSON.parse($stdin.read(length))
rescue JSON::ParserError
  respond('400 Bad Request', 'error' => 'body is not JSON')
end

action = request['action'].to_s
respond('400 Bad Request', 'error' => "action must be one of #{ACTIONS.keys.join(', ')}") unless ACTIONS.key?(action)

job = { 'action' => action, 'requested_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%z'), 'via' => 'dashboard', 'from' => ENV['REMOTE_ADDR'] }
if request.key?('path') && ACTIONS[action].include?('path')
  path = request['path'].to_s
  # Only files inside the local library, by a plain absolute path.
  unless path.start_with?("#{MEDIA_ROOT}/") && !path.include?('/../') && !path.include?("\0")
    respond('400 Bad Request', 'error' => "path must be under #{MEDIA_ROOT}")
  end
  job['path'] = path
else
  hash = request['hash'].to_s.downcase
  respond('400 Bad Request', 'error' => 'hash must be 40 hex characters') unless hash =~ /\A[0-9a-f]{40}\z/
  job['hash'] = hash
end
job['keep_link'] = true if request['keep_link'] == true
job['keep_library'] = false if request['keep_library'] == false
name = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{'%08x' % rand(2**32)}.json"
begin
  path = File.join(QUEUE, name)
  File.write("#{path}.tmp", JSON.pretty_generate(job))
  File.rename("#{path}.tmp", path)
rescue SystemCallError => e
  respond('500 Internal Server Error', 'error' => "cannot write to #{QUEUE}: #{e.message}. On the Mac: mkdir -p #{QUEUE} && chmod 1777 #{QUEUE}")
end

respond('202 Accepted', 'queued' => name, 'action' => action, 'hash' => job['hash'], 'path' => job['path'])
