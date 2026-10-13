# frozen_string_literal: true

require 'logger'
require_relative 'job_queue'
require_relative 'notify'
require_relative 'promoter'
require_relative 'transfer_dashboard'
require_relative 'transfer_log'

# Runs queued requests (see JobQueue) and records what happened: a line in
# the transfer log so the dashboard and the web UI show the new state, the
# job's own status and log files, a notification, and a dashboard refresh.
class TransfersWorker
  ACTIONS = %w[promote].freeze

  def initialize(queue:, promoter:, transfer_log: TransferLog.new, logger: Logger.new($stdout),
                 regenerate: lambda { TransferDashboard.generate(quiet: true) }, notify: Notify.method(:push))
    @queue = queue
    @promoter = promoter
    @transfer_log = transfer_log
    @log = logger
    @regenerate = regenerate
    @notify = notify
  end

  # Processes everything in the queue. Returns the jobs run.
  def process!
    jobs = []
    @queue.pending.each do |file|
      job = @queue.take(file)
      next if job.nil?

      jobs << job
      run(job)
    end
    jobs
  end

  # Runs one job to completion, never raising: failures land in the job's
  # status, the transfer log and a notification.
  def run(job)
    request = job.request
    request['hash'] = request['hash'].to_s.downcase if request['hash']
    action = request['action'].to_s
    subject = (request['hash'] || request['path']).to_s
    job.start!(action, subject)
    job.log "Started #{action} #{subject}"
    begin
      raise "Unknown action #{action.inspect}" unless ACTIONS.include?(action)

      message = send("do_#{action}", job, request)
      job.finish!('done', message)
      job.log "Done: #{message}"
      @log.info "#{job.id}: #{message}"
    rescue StandardError => e
      job.finish!('failed', "#{e.class}: #{e.message}")
      job.log "FAILED: #{e.class}: #{e.message}"
      e.backtrace.first(8).each { |line| job.log "  #{line}" }
      @log.error "#{job.id}: #{e.class}: #{e.message}"
      record_failure(action, request, e, job)
      @notify.call("#{subject}\n#{e.class}: #{e.message}", title: "#{action.capitalize} failed", priority: :high,
                                                                url: TransferDashboard.url, url_title: 'Open the dashboard')
    end
    refresh_dashboard(job)
  end

  # Finds the transfer record for a hash (newest first), or nil.
  def record_for(hash)
    wanted = hash.to_s.downcase
    @transfer_log.records.find { |r| (r['torrent'] || {})['hash'].to_s.downcase == wanted }
  end

  private

  def do_promote(job, request)
    keep_link = request['keep_link'] == true
    if request['hash']
      record = record_for(request['hash'])
      raise "No transfer record for hash #{request['hash']}" unless record

      job.log "Record: #{record['message']}"
      results = @promoter.promote_record(record, keep_link: keep_link)
    else
      record = { 'outcome' => 'file', 'torrent' => { 'name' => File.basename(request['path'].to_s) } }
      results = [@promoter.promote(request['path'].to_s, keep_link: keep_link)]
    end
    results.each { |r| job.log "#{r['source']} -> #{r['target']}#{r['still_seeding'] ? ' (still seeding)' : ''}" }

    message = promote_message(results)
    @transfer_log.append(
      'status' => 'ok', 'outcome' => record['outcome'], 'action' => 'promote', 'message' => message,
      'media_file' => results.first['source'], 'destination' => results.count == 1 ? results.first['target'] : File.dirname(results.first['target']),
      'destinations' => results.map { |r| r['target'] }, 'torrent' => record['torrent'], 'job' => job.id,
      'repro' => "#{worker_path} promote #{request['hash'] || request['path']}#{keep_link ? ' --keep-link' : ''}"
    )
    @notify.call(message, title: 'Promoted to NAS', url: TransferDashboard.url, url_title: 'Open the dashboard')
    message
  end

  def promote_message(results)
    names = results.map { |r| File.basename(r['target']) }
    where = File.dirname(results.first['target'])
    seeding = results.count { |r| r['still_seeding'] }
    head = results.count == 1 ? "Promoted #{names.first} to #{where}" : "Promoted #{results.count} files to #{where}"
    tail = seeding.positive? ? "; #{seeding == results.count ? 'download copy' : "#{seeding} download copies"} kept for seeding" : ''
    head + tail
  end

  def record_failure(action, request, error, job)
    record = request['hash'] ? record_for(request['hash']) : nil
    @transfer_log.append(
      'status' => 'error', 'outcome' => record ? record['outcome'] : 'error', 'action' => action,
      'message' => "#{action.capitalize} failed: #{error.class}: #{error.message}",
      'media_file' => request['path'], 'destination' => nil, 'job' => job.id,
      'torrent' => record ? record['torrent'] : request['path'] && { 'name' => File.basename(request['path'].to_s) },
      'error' => { 'class' => error.class.name, 'message' => error.message, 'backtrace' => Array(error.backtrace).first(10) },
      'repro' => "#{worker_path} #{action} #{request['hash'] || request['path']}"
    )
  rescue StandardError => e
    @log.error "Could not record failure: #{e.class}: #{e.message}"
  end

  def refresh_dashboard(job)
    @regenerate.call
  rescue StandardError => e
    job.log "Dashboard refresh failed: #{e.class}: #{e.message}"
  end

  def worker_path
    File.expand_path('../transfers-worker.rb', __dir__)
  end
end
