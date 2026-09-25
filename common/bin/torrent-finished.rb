#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Transmission "call script when download completes" hook.
#
# Reads the TR_TORRENT_* environment Transmission provides, symlinks the media
# where Plex will find it, records the outcome in the transfer log, sends a
# Pushover notification and refreshes the dashboard.
#
# Point Transmission at torrent-finished.sh rather than this file: the wrapper
# fixes PATH (Transmission launches scripts with a bare environment) and
# captures stdout/stderr, so even a Ruby that fails to start leaves a trace.
#
# See README-transfers.md for setup.

require 'fileutils'
require 'logger'
require_relative 'lib/notify'
require_relative 'lib/torrent_handler'
require_relative 'lib/transfer_dashboard'
require_relative 'lib/transfer_log'

$stdout.sync = true # keep stdout and stderr in order in the wrapper's capture file

# Configuration
MEDIA_ROOT = '/Users/theater/Media'
TV_DIRECTORY = File.join(MEDIA_ROOT, 'tv')
MOVIE_DIRECTORY = File.join(MEDIA_ROOT, 'movies')
LOG_FILE = ENV['TORRENT_FINISHED_LOG'] || '~/logs/torrent-finished.log'
LOG_FILES = 10
LOG_BYTES = 10 * 1024 * 1024 # per file; the previous 1024 discarded nearly everything

# DO NOT MODIFY BELOW THIS LINE #

# Writes to the rotating log file and to stdout (which the wrapper captures).
class TeeLogger
  def initialize(logger)
    @logger = logger
  end

  %i[info warn error fatal].each do |level|
    define_method(level) do |message|
      puts message
      @logger.send(level, message)
    end
  end
end

def build_logger
  path = File.expand_path(LOG_FILE)
  FileUtils.mkdir_p(File.dirname(path))
  TeeLogger.new(Logger.new(path, LOG_FILES, LOG_BYTES))
end

# The command line that re-runs this script for the same torrent.
class Repro
  def self.cmd
    environment = ENV.keys.select { |k| k.start_with? 'TR_TORRENT_' }.sort.map { |k| "#{k}='#{ENV[k]}'" }.join(' ')
    script = File.expand_path(__FILE__)
    "/usr/bin/env #{environment} ruby #{script}"
  end
end

def notify_outcome(torrent, outcome)
  name = torrent ? torrent.name : '(unknown torrent)'
  case outcome.outcome
  when 'tv'
    Notify.push(outcome.message, title: 'TV ready')
  when 'movie'
    Notify.push(outcome.message, title: 'Movie ready')
  when 'error', 'no_torrent'
    Notify.push("#{name}\n#{outcome.message}", title: 'Transfer failed', priority: :high)
  else
    Notify.push("#{name}\n#{outcome.message}", title: 'Transfer needs attention')
  end
end

def handle(torrent, log)
  return Outcome.error('No torrent in environment (TR_TORRENT_NAME / TR_TORRENT_DIR missing)', outcome: 'no_torrent') if torrent.nil?

  TorrentHandler.new(torrent, tv_directory: TV_DIRECTORY, movie_directory: MOVIE_DIRECTORY, logger: log).run!
rescue StandardError => e
  log.error "#{e.class}: #{e.message}\n  #{Array(e.backtrace).first(10).join("\n  ")}"
  Outcome.error("#{e.class}: #{e.message}", exception: e)
end

def main
  log = build_logger
  started = Time.now
  log.info "STARTING: #{Repro.cmd}"

  torrent = Torrent.from_env
  outcome = handle(torrent, log)
  duration = (Time.now - started).round(1)
  log.send(outcome.ok? ? :info : (outcome.error? ? :error : :warn),
           "#{outcome.status.upcase} (#{outcome.outcome}): #{outcome.message}")

  notified = notify_outcome(torrent, outcome)

  record = outcome.to_h.merge(
    'torrent' => torrent && torrent.to_h,
    'duration_s' => duration,
    'notified' => notified,
    'repro' => Repro.cmd
  )
  begin
    TransferLog.new.append(record)
  rescue StandardError => e
    log.error "Failed to record transfer: #{e.class}: #{e.message}"
  end

  begin
    TransferDashboard.generate(quiet: true)
  rescue StandardError => e
    log.error "Failed to regenerate dashboard: #{e.class}: #{e.message}"
  end

  log.info "FINISHED: #{outcome.status} in #{duration}s"
  outcome.error? ? 1 : 0
end

exit main if $PROGRAM_NAME == __FILE__
