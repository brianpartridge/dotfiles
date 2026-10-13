#!/usr/bin/ruby
# frozen_string_literal: true
#
# The dashboard's one write endpoint: queues a job for transfers-worker.rb.
# Deployed by transmission-web-deploy.sh to /Library/WebServer/CGI-Executables
# and reached as /transfers/api (see common/conf/apache/transmission.conf).
#
# Runs as Apache's _www user with the system Ruby, so it is self-contained:
# it validates the request and writes one small JSON file into the queue
# directory, which must be world-writable (chmod 1777). Everything else
# happens in the worker, as the real user.
#
#   POST /transfers/api
#   X-Requested-With: transfers          (browsers will not send this cross-site)
#   {"action":"promote","hash":"<40 hex>","keep_link":false}

require 'json'

QUEUE = ENV['TRANSFERS_QUEUE'] || '/Users/theater/logs/transfers-queue'
ACTIONS = %w[promote].freeze

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
hash = request['hash'].to_s.downcase
respond('400 Bad Request', 'error' => "action must be one of #{ACTIONS.join(', ')}") unless ACTIONS.include?(action)
respond('400 Bad Request', 'error' => 'hash must be 40 hex characters') unless hash =~ /\A[0-9a-f]{40}\z/

job = { 'action' => action, 'hash' => hash, 'keep_link' => request['keep_link'] == true,
        'requested_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%z'), 'via' => 'dashboard', 'from' => ENV['REMOTE_ADDR'] }
name = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{'%08x' % rand(2**32)}.json"
begin
  path = File.join(QUEUE, name)
  File.write("#{path}.tmp", JSON.pretty_generate(job))
  File.rename("#{path}.tmp", path)
rescue SystemCallError => e
  respond('500 Internal Server Error', 'error' => "cannot write to #{QUEUE}: #{e.message}. On the Mac: mkdir -p #{QUEUE} && chmod 1777 #{QUEUE}")
end

respond('202 Accepted', 'queued' => name, 'action' => action, 'hash' => hash)
