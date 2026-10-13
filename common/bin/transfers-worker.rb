#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Runs dashboard-triggered jobs. launchd starts it whenever the queue
# directory is non-empty (home-server/Library/LaunchAgents/
# com.brianpartridge.transfers-worker.plist); it can also be run by hand.
#
#   transfers-worker.rb                            process queued requests
#   transfers-worker.rb promote HASH|PATH [--keep-link]   run one promotion now
#   transfers-worker.rb enqueue promote HASH|PATH [--keep-link]   queue it for launchd
#
# See README-transfers.md, "Promoting to the NAS".

require 'logger'
require_relative 'lib/media_config'
require_relative 'lib/job_queue'
require_relative 'lib/promoter'
require_relative 'lib/transfers_worker'

$stdout.sync = true
logger = Logger.new($stdout)
logger.formatter = proc { |severity, time, _progname, msg| "#{time.strftime('%Y-%m-%d %H:%M:%S')} #{severity} #{msg}\n" }

queue = JobQueue.new(queue_dir: MediaConfig::QUEUE_DIR, jobs_dir: MediaConfig::JOBS_DIR)
promoter = Promoter.new(nas_root: MediaConfig::NAS_ROOT, media_root: MediaConfig::MEDIA_ROOT, logger: logger)
worker = TransfersWorker.new(queue: queue, promoter: promoter, logger: logger)

def request_from(args)
  action = args.shift
  subject = args.shift
  abort "Usage: transfers-worker.rb [enqueue] #{TransfersWorker::ACTIONS.join('|')} HASH|PATH [--keep-link]" if subject.nil?
  abort "Unknown action #{action}" unless TransfersWorker::ACTIONS.include?(action)

  params = subject =~ /\A[0-9a-f]{40}\z/i ? { 'hash' => subject.downcase } : { 'path' => File.expand_path(subject) }
  params['keep_link'] = true if args.include?('--keep-link')
  [action, params]
end

case ARGV.first
when nil
  jobs = worker.process!
  logger.info "Processed #{jobs.count} job(s)" unless jobs.empty?
when 'enqueue'
  ARGV.shift
  action, params = request_from(ARGV)
  puts "Queued #{File.basename(queue.enqueue(action, params))}"
else
  action, params = request_from(ARGV)
  file = queue.enqueue(action, params)
  job = queue.take(file)
  worker.run(job)
  status = job.status || {}
  puts "#{status['state']}: #{status['message']}"
  exit(status['state'] == 'done' ? 0 : 1)
end
