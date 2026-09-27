#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Transmission "call script when download completes" hook.
#
# Reads the TR_TORRENT_* environment Transmission provides, hardlinks the media
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
# Where eBooks, comics, audiobooks and music go. They are copied (not linked)
# only when this script runs with --file-other; by default they are recorded
# and the command to file them later is included in the notification, the log
# and the dashboard.
DROPBOX_MEDIA = File.expand_path(ENV['DROPBOX_MEDIA'] || '~/Dropbox/media')
OTHER_DIRECTORIES = {
  'comic' => File.join(DROPBOX_MEDIA, 'comics'),
  'ebook' => File.join(DROPBOX_MEDIA, 'ebooks'),
  'audiobook' => File.join(DROPBOX_MEDIA, 'audiobooks'),
  'music' => File.join(DROPBOX_MEDIA, 'music')
}.freeze
FILE_OTHER_FLAG = '--file-other'
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

# The command that files a recognised-but-unfiled download, or nil.
def file_command(outcome)
  return nil unless outcome.other? && OTHER_DIRECTORIES.key?(outcome.outcome)

  "#{Repro.cmd} #{FILE_OTHER_FLAG}"
end

def notify_outcome(torrent, outcome)
  name = torrent ? torrent.name : '(unknown torrent)'
  kind = TorrentHandler::OTHER_LABELS[outcome.outcome]
  case outcome.outcome
  when 'tv'
    Notify.push(outcome.message, title: 'TV ready')
  when 'movie'
    Notify.push(outcome.message, title: 'Movie ready')
  when 'error', 'no_torrent'
    Notify.push("#{name}\n#{outcome.message}", title: 'Transfer failed', priority: :high)
  when 'ebook', 'comic', 'audiobook', 'music'
    if outcome.ok?
      Notify.push(outcome.message, title: "#{kind} filed")
    else
      body = "#{name}\n#{outcome.message}"
      command = file_command(outcome)
      body += "\n\nTo file it into #{OTHER_DIRECTORIES[outcome.outcome]}:\n#{command}" if command
      Notify.push(body, title: "#{kind} downloaded")
    end
  else
    Notify.push("#{name}\n#{outcome.message}", title: 'Transfer complete')
  end
end

def handle(torrent, log, file_other)
  return Outcome.error('No torrent in environment (TR_TORRENT_NAME / TR_TORRENT_DIR missing)', outcome: 'no_torrent') if torrent.nil?

  TorrentHandler.new(torrent, tv_directory: TV_DIRECTORY, movie_directory: MOVIE_DIRECTORY,
                              other_directories: OTHER_DIRECTORIES, file_other: file_other, logger: log).run!
rescue StandardError => e
  log.error "#{e.class}: #{e.message}\n  #{Array(e.backtrace).first(10).join("\n  ")}"
  Outcome.error("#{e.class}: #{e.message}", exception: e)
end

def main
  log = build_logger
  started = Time.now
  file_other = ARGV.include?(FILE_OTHER_FLAG)
  log.info "STARTING: #{Repro.cmd}#{file_other ? " #{FILE_OTHER_FLAG}" : ''}"

  torrent = Torrent.from_env
  outcome = handle(torrent, log, file_other)
  duration = (Time.now - started).round(1)
  log.send(outcome.error? ? :error : :info,
           "#{outcome.status.upcase} (#{outcome.outcome}): #{outcome.message}")

  notified = notify_outcome(torrent, outcome)

  record = outcome.to_h.merge(
    'torrent' => torrent && torrent.to_h,
    'duration_s' => duration,
    'notified' => notified,
    'repro' => Repro.cmd,
    'file_command' => file_command(outcome)
  )
  log.info "To file it later: #{record['file_command']}" if record['file_command']
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
