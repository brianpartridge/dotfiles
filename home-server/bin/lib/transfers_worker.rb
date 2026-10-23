# frozen_string_literal: true

require 'logger'
require 'open3'
require 'rbconfig'
require_relative 'job_queue'
require_relative 'media_dashboard'
require_relative 'media_remover'
require_relative 'notify'
require_relative 'promoter'
require_relative 'transfer_dashboard'
require_relative 'transfer_log'
require_relative 'transmission_rpc'

# Runs queued requests (see JobQueue) and records what happened: a line in
# the transfer log so the dashboard and the web UI show the new state, the
# job's own status and log files, a notification, and a dashboard refresh.
class TransfersWorker
  ACTIONS = %w[promote remove_torrent unlink_library rerun_finish].freeze
  FINISH_SCRIPT = File.expand_path('../torrent-finished.rb', __dir__)

  # torrent-finished.rb failed and already recorded and announced that, so
  # the worker records nothing more.
  class FinishScriptFailed < StandardError; end

  def initialize(queue:, promoter:, remover: nil, rpc: nil, transfer_log: TransferLog.new, logger: Logger.new($stdout),
                 regenerate: TransfersWorker.method(:regenerate_dashboards), notify: Notify.method(:push),
                 finisher: TransfersWorker.method(:run_finish_script))
    @queue = queue
    @promoter = promoter
    @remover = remover
    @rpc = rpc
    @finisher = finisher
    @transfer_log = transfer_log
    @log = logger
    @regenerate = regenerate
    @notify = notify
  end

  # Both pages; the media page's failure is logged, never fatal.
  def self.regenerate_dashboards
    TransferDashboard.generate(quiet: true)
    begin
      MediaDashboard.generate(quiet: true)
    rescue StandardError => e
      warn "media page not written: #{e.class}: #{e.message}"
    end
  end

  # Runs torrent-finished.rb the way Transmission does, with the TR_TORRENT_*
  # environment, under this Ruby. Returns [combined output, success?].
  def self.run_finish_script(env)
    output, status = Open3.capture2e(env, RbConfig.ruby, FINISH_SCRIPT)
    [output, status.success?]
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
      unless e.is_a?(FinishScriptFailed)
        record_failure(action, request, e, job)
        @notify.call("#{subject}\n#{e.class}: #{e.message}", title: "#{action.capitalize} failed", priority: :high,
                                                                  url: TransferDashboard.url, url_title: 'Open the dashboard')
      end
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

  # Remove a torrent and its data; the library keeps its bytes unless asked otherwise.
  def do_remove_torrent(job, request)
    keep = request['keep_library'] != false
    record = record_for(request['hash'])
    result = remover.remove_torrent(request['hash'], keep_library: keep)
    result['kept'].each { |p| job.log "Kept in library: #{p}" }
    result['removed_library'].each { |p| job.log "Removed from library: #{p}" }
    message = "Removed #{result['torrent']} from Transmission (ratio #{result['ratio']}), freed #{TransferDashboard.size_label(result['freed'])}"
    message += keep ? "; #{result['kept'].count} library file(s) kept" : "; #{result['removed_library'].count} library file(s) removed"
    @transfer_log.append(
      'status' => 'ok', 'outcome' => record ? record['outcome'] : 'unknown_media', 'action' => 'remove', 'message' => message,
      'media_file' => nil, 'destination' => nil, 'freed' => result['freed'], 'kept' => result['kept'],
      'torrent' => record ? record['torrent'] : { 'name' => result['torrent'], 'hash' => result['hash'] }, 'job' => job.id,
      'repro' => "#{worker_path} remove_torrent #{request['hash']}#{keep ? '' : ' --remove-library'}"
    )
    @notify.call(message, title: 'Torrent removed', url: TransferDashboard.url, url_title: 'Open the dashboard')
    message
  end

  # Remove local library entries only (bytes stay with the download and the NAS).
  def do_unlink_library(job, request)
    record = request['hash'] ? record_for(request['hash']) : nil
    result = remover.unlink_library(hash: request['hash'], path: request['path'])
    result['removed_library'].each { |p| job.log "Removed from library: #{p}" }
    names = result['removed_library'].map { |p| File.basename(p) }
    message = names.count == 1 ? "Removed #{names.first} from the local library" : "Removed #{names.count} files from the local library"
    @transfer_log.append(
      'status' => 'ok', 'outcome' => record ? record['outcome'] : 'file', 'action' => 'unlink', 'message' => message,
      'media_file' => result['removed_library'].first, 'destination' => nil, 'job' => job.id,
      'torrent' => record ? record['torrent'] : { 'name' => names.first },
      'repro' => "#{worker_path} unlink_library #{request['hash'] || request['path']}"
    )
    @notify.call(message, title: 'Removed from library', url: TransferDashboard.url, url_title: 'Open the dashboard')
    message
  end

  # Runs torrent-finished.rb again for a torrent, for example when the first
  # run failed. The script records the outcome and sends the notification.
  def do_rerun_finish(job, request)
    torrent = finished_torrent(request['hash'], job)
    env = { 'TR_TORRENT_NAME' => torrent['name'], 'TR_TORRENT_DIR' => torrent['directory'],
            'TR_TORRENT_HASH' => request['hash'], 'TR_TORRENT_ID' => torrent['id'].to_s }
    job.log "Running #{FINISH_SCRIPT} for #{File.join(torrent['directory'], torrent['name'])}"
    output, ok = @finisher.call(env)
    output.to_s.each_line { |line| job.log "  #{line.chomp}" }
    record = record_for(request['hash'])
    result = record ? record['message'] : 'no transfer record written'
    raise FinishScriptFailed, "torrent-finished.rb failed: #{result}" unless ok

    "Re-ran torrent-finished.rb: #{result}"
  end

  # Where the torrent's data is. Transmission knows best; the newest transfer
  # record is the fallback when Transmission is unreachable or has removed it.
  def finished_torrent(hash, job)
    begin
      found = rpc.torrents.find { |t| t['hashString'].to_s.downcase == hash }
      if found
        raise "#{found['name']} is still downloading (#{(found['percentDone'].to_f * 100).round}%)" if found['percentDone'].to_f < 1.0

        return { 'name' => found['name'], 'directory' => found['downloadDir'], 'id' => found['id'] }
      end
      job.log 'Transmission does not know this torrent; using the transfer record'
    rescue TransmissionRPC::Error => e
      job.log "Transmission unreachable (#{e.message}); using the transfer record"
    end
    torrent = (record_for(hash) || {})['torrent'] || {}
    raise "Cannot find torrent #{hash} in Transmission or the transfer log" if torrent['name'].to_s.empty? || torrent['directory'].to_s.empty?

    torrent
  end

  def rpc
    @rpc ||= TransmissionRPC.from_config
  end

  def remover
    @remover ||= MediaRemover.new(rpc: rpc, media_root: MediaConfig::MEDIA_ROOT, logger: @log)
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
