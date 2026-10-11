# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

# Append-only, one-JSON-object-per-line record of every handled transfer.
# This is the source of truth for the dashboard; the text log is for humans.
#
# Record shape (all keys are strings):
#
#   ts          ISO 8601 time the record was written
#   status      "ok" (filed for Plex) | "other" (finished, nothing to file) | "error"
#   outcome     "tv" | "movie" (filed) | "ebook" | "comic" | "audiobook" | "music"
#               (recognised, not filed) | "no_media" | "multiple_media" |
#               "unknown_media" | "error" | "no_torrent"
#   action      "link" (hardlink) | "symlink" (different volume) | "extract_link" |
#               "extract_symlink" | "copy" (eBooks, comics, audiobooks, music) | "none"
#   message     human readable summary
#   media_file  path of the file that was filed (the torrent directory for a set)
#   destination the link that was created (its directory for a set)
#   torrent     { name, directory, hash, id } as reported by Transmission
#   error       { class, message, backtrace } when an exception occurred
#   duration_s  seconds the handler took
#   notified    whether the Pushover notification was accepted
#   repro       command line to re-run the handler for this torrent
#   file_command for a recognised-but-unfiled eBook/comic/audiobook/music
#               download, the command that copies it into place
class TransferLog
  DEFAULT_PATH = '~/logs/transfers.jsonl'
  STATUSES = %w[ok other error].freeze
  OUTCOMES = %w[tv movie ebook comic audiobook music no_media multiple_media unknown_media error no_torrent].freeze

  attr_reader :path

  def initialize(path = nil)
    @path = File.expand_path(path || ENV['TRANSFER_LOG'] || DEFAULT_PATH)
  end

  # Appends a record and returns it as written (string keys, with "ts").
  def append(record)
    record = { 'ts' => Time.now.iso8601 }.merge(normalize(record))
    FileUtils.mkdir_p(File.dirname(@path))
    File.open(@path, 'a') do |f|
      f.flock(File::LOCK_EX)
      f.puts(JSON.generate(record))
    end
    record
  end

  # Records newest first. Malformed lines (e.g. a partial write) are skipped.
  def records(limit: nil)
    return [] unless File.file?(@path)

    all = []
    File.foreach(@path) do |line|
      line = line.strip
      next if line.empty?

      begin
        all << JSON.parse(line)
      rescue JSON::ParserError
        next
      end
    end
    all.reverse!
    limit ? all.first(limit) : all
  end

  def self.time_of(record)
    Time.iso8601(record['ts'].to_s)
  rescue ArgumentError
    nil
  end

  private

  # Round-trips through JSON so symbol keys and nested objects come back the
  # same way they will when read.
  def normalize(record)
    JSON.parse(JSON.generate(record))
  end
end
