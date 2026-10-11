# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'set'
require_relative 'episode_id'
require_relative 'movie_id'

# A completed torrent as described by Transmission's done-script environment.
class Torrent
  attr_reader :name, :directory, :hash, :id

  def initialize(name, directory, hash: nil, id: nil)
    @name = name
    @directory = directory
    @hash = hash
    @id = id
  end

  # nil when the environment does not describe a torrent.
  def self.from_env(env = ENV)
    name = env['TR_TORRENT_NAME']
    dir = env['TR_TORRENT_DIR']
    return nil if name.nil? || name.empty? || dir.nil? || dir.empty?

    Torrent.new(name, dir, hash: env['TR_TORRENT_HASH'], id: env['TR_TORRENT_ID'])
  end

  def path
    File.join(@directory, @name)
  end

  # Every regular file in the download, recursively, ignoring dotfiles.
  def files
    return [path] unless File.directory?(path)

    # chdir rather than Dir.glob(base:) so this runs on the system Ruby 2.3;
    # it also sidesteps glob metacharacters ([ ] { }) in torrent names.
    Dir.chdir(path) { Dir.glob('**/*') }
       .reject { |f| File.basename(f).start_with?('.') }
       .map { |f| File.join(path, f) }
       .select { |f| File.file?(f) }
       .sort
  end

  def to_h
    { 'name' => @name, 'directory' => @directory, 'hash' => @hash, 'id' => @id }
  end
end

# Classification of files inside a download.
module MediaFile
  EXTENSIONS = %w[.mkv .avi .mov .mp4 .m4v].freeze
  BLACKLIST = %w[sample].freeze

  def self.valid?(path)
    return false unless File.file?(path)

    name = File.basename(path).downcase
    return false if BLACKLIST.any? { |term| name.include?(term) }

    EXTENSIONS.include?(File.extname(name))
  end

  def self.rar?(path)
    File.file?(path) && File.extname(path).casecmp('.rar').zero?
  end

  # The archives worth extracting. A multi-volume set (foo.part01.rar,
  # foo.part02.rar, ...) counts once, via its first volume.
  def self.primary_rars(files)
    rars = files.select { |f| rar?(f) }
    parts = rars.select { |f| File.basename(f) =~ /\.part\d+\.rar\z/i }
    return rars if parts.empty?

    (rars - parts) + parts.select { |f| File.basename(f) =~ /\.part0*1\.rar\z/i }
  end
end

# Recognises downloads that are not video: eBooks, comics, audiobooks and
# music. These are classified and recorded but not filed anywhere.
module OtherMedia
  EBOOK = %w[.epub .mobi .azw .azw3].freeze
  COMIC = %w[.cbr .cbz .cb7 .cbt].freeze
  PDF = '.pdf'
  AUDIOBOOK_SINGLE = %w[.m4b].freeze
  AUDIO = %w[.mp3 .m4a .aac .ogg .opus .wma .flac .ape .wav .aiff].freeze
  # Formats that are essentially never audiobooks, and the sidecars of a CD rip.
  MUSIC_ONLY = %w[.flac .ape .wav .aiff .cue .log].freeze
  # With no other evidence, this many audio files is a book; fewer is a single.
  AUDIO_MIN_FILES = 3
  # PDFs are eBooks unless the name looks like a comic release.
  COMIC_NAME_HINT = /\b(comics?|graphic novel|digital|tpb|webrip|v\d{1,3}|#\d+|\d{3}\s*\(\d{4}\))\b/i
  AUDIOBOOK_NAME_HINT = /\b(audio ?books?|unabridged|abridged|narrat(ed|or|ion)|read by|\d{2,3} ?kbps|64k)\b/i
  MUSIC_NAME_HINT = /\b(flac|lossless|320|v0|v2|vinyl|album|ep|single|discography|soundtrack|ost|remaster(ed)?|deluxe|live|cd\d*|web|24 ?bit|16 ?bit)\b/i
  CHAPTER_FILE_HINT = /\b(chapter|chap|ch|part|pt)\.?\s?\d+/i

  # [kind, description] or nil. kind is 'ebook', 'comic', 'audiobook' or 'music'.
  def self.classify(files, name)
    ext = files.group_by { |f| File.extname(f).downcase }
    count = lambda { |exts| exts.inject(0) { |n, e| n + (ext[e] || []).count } } # Array#sum needs Ruby 2.4

    return ['comic', summary(ext, COMIC + [PDF])] if count.call(COMIC).positive?
    return ['ebook', summary(ext, EBOOK + [PDF])] if count.call(EBOOK).positive?
    if count.call([PDF]).positive?
      kind = name =~ COMIC_NAME_HINT ? 'comic' : 'ebook'
      return [kind, summary(ext, [PDF])]
    end
    return ['audiobook', summary(ext, AUDIOBOOK_SINGLE + AUDIO)] if count.call(AUDIOBOOK_SINGLE).positive?
    return nil unless count.call(AUDIO).positive?

    [audio_kind(files, ext, name, count.call(AUDIO)), summary(ext, AUDIO)]
  end

  # Audiobook or music, for a download that is audio files. Each rule is a
  # piece of evidence; the last one is the fallback.
  def self.audio_kind(files, ext, name, audio_count)
    return 'audiobook' if name =~ AUDIOBOOK_NAME_HINT
    return 'music' if MUSIC_ONLY.any? { |e| ext.key?(e) }
    return 'music' if name =~ MUSIC_NAME_HINT

    audio = files.select { |f| AUDIO.include?(File.extname(f).downcase) }
    chaptered = audio.count { |f| File.basename(f) =~ CHAPTER_FILE_HINT }
    return 'audiobook' if chaptered * 2 >= audio.count && chaptered.positive?

    audio_count >= AUDIO_MIN_FILES ? 'audiobook' : 'music'
  end

  def self.summary(ext, exts)
    exts.select { |e| ext.key?(e) }.map { |e| "#{ext[e].count} #{e.sub('.', '')}" }.join(', ')
  end
end

# The result of handling one torrent. Serialises into a TransferLog record.
class Outcome
  attr_reader :status, :outcome, :action, :message, :media_file, :destination, :error

  def initialize(status:, outcome:, message:, action: 'none', media_file: nil, destination: nil, error: nil)
    @status = status
    @outcome = outcome
    @message = message
    @action = action
    @media_file = media_file
    @destination = destination
    @error = error
  end

  def self.ok(outcome, message, **rest)
    new(status: 'ok', outcome: outcome, message: message, **rest)
  end

  # Finished fine, but there was nothing to file for Plex: not a TV episode
  # or a movie, no media files at all, or nothing to pick from an archive.
  def self.other(outcome, message, **rest)
    new(status: 'other', outcome: outcome, message: message, **rest)
  end

  def self.error(message, outcome: 'error', exception: nil, **rest)
    error = nil
    if exception
      error = {
        'class' => exception.class.name,
        'message' => exception.message,
        'backtrace' => Array(exception.backtrace).first(15)
      }
    end
    new(status: 'error', outcome: outcome, message: message, error: error, **rest)
  end

  def ok?
    @status == 'ok'
  end

  def other?
    @status == 'other'
  end

  def error?
    @status == 'error'
  end

  def to_h
    {
      'status' => @status,
      'outcome' => @outcome,
      'action' => @action,
      'message' => @message,
      'media_file' => @media_file,
      'destination' => @destination,
      'error' => @error
    }
  end
end

# Hardlinks a completed torrent's media where Plex will find it, so the
# torrent keeps seeding from where it is and removing either side leaves the
# other intact.
#
# Raises for genuine failures (destination volume missing, link blocked, unrar
# failed); the caller turns those into an error Outcome so they are recorded
# and notified rather than lost.
class TorrentHandler
  # other_directories maps an OtherMedia kind ('ebook', 'comic', 'audiobook',
  # 'music') to the directory it should be copied into. Copying only happens
  # when file_other is true; otherwise those downloads are recorded as
  # recognised but not filed.
  def initialize(torrent, tv_directory:, movie_directory:, logger:, other_directories: {}, file_other: false)
    @torrent = torrent
    @tv_directory = tv_directory
    @movie_directory = movie_directory
    @other_directories = other_directories
    @file_other = file_other
    @log = logger
  end

  OTHER_LABELS = { 'ebook' => 'eBook', 'comic' => 'Comic', 'audiobook' => 'Audiobook', 'music' => 'Music' }.freeze

  def run!
    files = @torrent.files
    media = files.select { |f| MediaFile.valid?(f) }
    rars = MediaFile.primary_rars(files)
    @log.info "#{files.count} files, #{media.count} media, #{rars.count} archives in #{@torrent.path}"

    if media.count == 1
      handle_media(media.first)
    elsif media.count > 1
      handle_media_set(media)
    elsif rars.count == 1
      extract_and_handle(rars.first)
    else
      classify_other(files, rars)
    end
  end

  private

  def extract_and_handle(rar)
    directory = File.dirname(rar)
    @log.info "Extracting #{rar}"
    before = Set.new(@torrent.files)
    result = system('unrar', 'x', '-o+', '-y', rar, chdir: directory)
    raise 'unrar not found on PATH' if result.nil?
    raise "unrar exited with status #{$CHILD_STATUS.exitstatus} for #{rar}" unless result

    after = @torrent.files
    new_media = (Set.new(after) - before).select { |f| MediaFile.valid?(f) }
    if new_media.count == 1
      handle_media(new_media.first, extracted: true)
    elsif new_media.empty?
      classify_other(after, [], "Archive #{File.basename(rar)} contained no video")
    else
      handle_media_set(new_media, extracted: true)
    end
  end

  # No video to file. Say what the download is, if it is something we
  # recognise (books, comics, audiobooks, music), without moving anything.
  def classify_other(files, rars, prefix = nil)
    kind, description = OtherMedia.classify(files, @torrent.name)
    if kind
      summary = [prefix, "#{OTHER_LABELS[kind]}: #{description}"].compact.join('; ')
      directory = @other_directories[kind]
      return copy_other(kind, directory, summary) if @file_other && directory

      return Outcome.other(kind, "#{summary}; not filed", media_file: @torrent.path)
    end
    if rars.count > 1
      return Outcome.other('multiple_media', "#{rars.count} archives and no media files; nothing to pick")
    end

    Outcome.other('no_media', [prefix, "No media files among #{files.count} files"].compact.join('; '))
  end

  # :tv, :movie or nil for a release name.
  def classify(name)
    return :tv if EpisodeID.from_release(name)
    return :movie if MovieID.from_release(name)

    nil
  end

  # A season pack, or a movie with extras: the torrent's name describes the
  # set, so each file is classified and filed on its own name. Files that are
  # neither TV nor a movie are skipped, which is fine as long as something
  # was filed.
  def handle_media_set(media, extracted: false)
    results = media.map { |path| handle_media(path, extracted: extracted, by_filename: true) }
    filed = results.select(&:ok?)
    skipped = results.reject(&:ok?).map { |o| File.basename(o.media_file) }
    action = extracted ? 'extract_link' : 'link'
    kinds = filed.map(&:outcome).uniq
    destination = kinds.count == 1 ? File.dirname(filed.first.destination) : nil

    if filed.empty?
      Outcome.other('unknown_media',
                    "None of #{media.count} media files recognised as TV or a movie: #{skipped.join(', ')}",
                    media_file: @torrent.path)
    else
      message = "Linked #{filed.count} of #{media.count} media files (#{kinds.join(' and ')}) into #{destination || 'tv and movies'}"
      message += "; skipped: #{skipped.join(', ')}" unless skipped.empty?
      Outcome.ok(kinds == ['movie'] ? 'movie' : 'tv', message,
                 action: action, media_file: @torrent.path, destination: destination)
    end
  end

  # Files one media file. Classified by the torrent name, falling back to the
  # file's own name; by_filename skips the torrent name (see handle_media_set).
  #
  # The link is named after whichever name classified it. A directory torrent
  # "Some.Movie.2019.1080p-GRP" often holds "grp-smv.mkv", and Plex needs the
  # former, so the link becomes "Some.Movie.2019.1080p-GRP.mkv".
  def handle_media(path, extracted: false, by_filename: false)
    filename = File.basename(path)
    kind = by_filename ? classify(filename) : classify(@torrent.name)
    named_by_file = by_filename
    if kind.nil? && !by_filename
      kind = classify(filename)
      named_by_file = true
    end
    link_name = named_by_file ? filename : torrent_link_name(path)
    origin = link_name == filename ? '' : " (from #{filename})"
    case kind
    when :tv
      @log.info "Found episode: #{filename}"
      destination, note, action = link_file(path, @tv_directory, link_name)
      Outcome.ok('tv', "#{note} #{link_name}#{origin} into #{@tv_directory}",
                 action: extracted ? "extract_#{action}" : action, media_file: path, destination: destination)
    when :movie
      @log.info "Found movie: #{filename}"
      destination, note, action = link_file(path, @movie_directory, link_name)
      Outcome.ok('movie', "#{note} #{link_name}#{origin} into #{@movie_directory}",
                 action: extracted ? "extract_#{action}" : action, media_file: path, destination: destination)
    else
      Outcome.other('unknown_media', "'#{by_filename ? filename : @torrent.name}' is not a TV episode or a movie",
                    media_file: path)
    end
  end

  # Copies the torrent's data as it is, a single file or the whole directory,
  # into the kind's directory. Copied under a temporary name and renamed, so
  # a sync client never sees a half-copied item.
  def copy_other(kind, directory, summary)
    parent = File.dirname(directory)
    raise "Destination directory is missing (volume not mounted?): #{parent}" unless File.directory?(parent)

    FileUtils.mkdir_p(directory)
    source = @torrent.path
    destination = File.join(directory, File.basename(source))
    if File.exist?(destination)
      @log.info "Already present, not copying: #{destination}"
      return Outcome.ok(kind, "Already had #{File.basename(source)} in #{directory}; #{summary}",
                        action: 'copy', media_file: source, destination: destination)
    end

    tmp = "#{destination}.copying"
    FileUtils.rm_rf(tmp)
    @log.info "Copying #{source} to #{destination}"
    FileUtils.cp_r(source, tmp)
    File.rename(tmp, destination)
    @log.info 'Copy complete'
    Outcome.ok(kind, "Copied #{File.basename(source)} into #{directory}; #{summary}",
               action: 'copy', media_file: source, destination: destination)
  end

  # The torrent's name with the media file's extension. For a single-file
  # torrent the torrent name is the file name already.
  def torrent_link_name(path)
    return File.basename(path) unless File.directory?(@torrent.path)

    ext = File.extname(path)
    @torrent.name.downcase.end_with?(ext.downcase) ? @torrent.name : "#{@torrent.name}#{ext}"
  end

  def ensure_directory(directory)
    return if File.directory?(directory)

    raise "Destination directory is missing (volume not mounted?): #{directory}"
  end

  # Hardlinks the file into the destination directory, so the library and
  # the torrent share one set of bytes and either can be deleted without
  # affecting the other. Falls back to a symlink when the destination is on a
  # different volume, where a hardlink is not possible.
  #
  # Returns [destination, note, action]
  def link_file(path, directory, link_name = File.basename(path))
    ensure_directory(directory)
    destination = File.join(directory, link_name)

    if File.symlink?(destination)
      # A link from the old symlink scheme, or a stale one: replace it.
      note = File.exist?(destination) ? 'Relinked' : 'Replaced stale link with'
      @log.info "#{note} #{destination}"
      return hardlink(path, destination, note)
    end
    if File.exist?(destination)
      if File.identical?(path, destination)
        @log.info "Already linked: #{destination}"
        return [destination, 'Already linked', 'link']
      end
      raise "Destination already exists and is a different file: #{destination}"
    end

    hardlink(path, destination, 'Linked')
  end

  def hardlink(path, destination, note)
    tmp = "#{destination}.linking"
    File.unlink(tmp) if File.symlink?(tmp) || File.exist?(tmp)
    begin
      File.link(path, tmp)
    rescue Errno::EXDEV
      @log.info "#{destination} is on a different volume; symlinking instead"
      File.symlink(path, tmp)
      File.rename(tmp, destination) # replaces any existing symlink atomically
      return [destination, "#{note.sub('Linked', 'Symlinked')} (different volume)", 'symlink']
    end
    File.rename(tmp, destination)
    @log.info "Hardlinked #{path} to #{destination}"
    [destination, note, 'link']
  end
end
