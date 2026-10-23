# frozen_string_literal: true

require 'set'
require 'time'
require_relative 'episode_id'
require_relative 'movie_id'
require_relative 'torrent_handler'
require_relative 'transfer_dashboard'
require_relative 'transfer_log'
require_relative 'transmission_rpc'

# Where every TV episode and movie is: downloading or seeding in
# Transmission, linked into the local library (~/Media), promoted to the NAS.
#
# The local library is hardlinks into the downloads, so a file in both places
# is stored once. Matching is by identity (device and inode), so it does not
# matter what either side is called; symlinks are matched by target. The NAS
# is never scanned: "on the NAS" comes from the transfer log's promotion
# records (and a symlink left behind by --keep-link), optionally confirmed by
# one stat per file when the volume happens to be mounted.
module MediaInventory
  TORRENT_FIELDS = (TransmissionRPC::TORRENT_FIELDS + %w[files uploadRatio]).freeze
  LIBRARY_KINDS = { 'tv' => 'tv', 'movies' => 'movie' }.freeze
  KIND_LABELS = { 'tv' => 'TV', 'movie' => 'Movie', 'unknown' => 'Unrecognised' }.freeze
  STATE_LABELS = {
    'downloading' => 'Downloading',
    'seeding' => 'Seeding, in library',
    'stopped' => 'Stopped, in library',
    'unfiled' => 'Downloaded, not in library',
    'promoted' => 'Seeding, on NAS only',
    'library_only' => 'Library only, not in Transmission'
  }.freeze
  LINK_LABELS = { 'hardlink' => 'hardlink', 'symlink' => 'symlink', 'copy' => 'separate copy' }.freeze

  # A video file in Transmission's download folder (declared by the torrent,
  # or extracted from one of its archives) or in the library, or both.
  class Item
    attr_accessor :name, :kind, :size, :download_path, :library_path, :link, :torrent, :extracted,
                  :on_disk, :library_size, :nas, :mtime
    attr_reader :warnings

    def initialize
      @warnings = []
      @extracted = false
      @on_disk = true
      @nas = nil
    end

    def in_library?
      !library_path.nil?
    end

    def in_transmission?
      !torrent.nil?
    end

    def on_nas?
      !nas.nil?
    end

    # Whether the library copy owns its own bytes if the download goes away.
    def library_depends_on_download?
      link == 'symlink'
    end

    def state
      if torrent
        return 'downloading' unless torrent['complete']
        return(torrent['seeding'] ? 'seeding' : 'stopped') if in_library?
        return 'promoted' if on_nas?

        'unfiled'
      else
        'library_only'
      end
    end

    # Bytes that removing the torrent's copy of this file would free.
    def frees_if_removed
      return 0 unless torrent && on_disk
      return 0 if link == 'hardlink'

      size.to_i
    end

    # Bytes this file occupies on disk, counted once however many names it has.
    def stored_bytes
      return size.to_i + library_size.to_i if link == 'copy'

      size.to_i
    end

    def to_h
      {
        'name' => name, 'kind' => kind, 'state' => state, 'size' => size, 'stored_bytes' => stored_bytes,
        'frees_if_removed' => frees_if_removed, 'download_path' => download_path, 'library_path' => library_path,
        'link' => link, 'extracted' => extracted, 'on_disk' => on_disk, 'nas' => nas, 'mtime' => mtime && mtime.iso8601,
        'warnings' => warnings
      }
    end
  end

  # Items that share a torrent, or one library-only item.
  class Group
    attr_reader :torrent, :items

    def initialize(torrent, items)
      @torrent = torrent
      @items = items
    end

    def name
      torrent ? torrent['name'] : items.first.name
    end

    def kind
      kinds = items.map(&:kind).uniq
      kinds.count == 1 ? kinds.first : 'unknown'
    end

    def state
      states = items.map(&:state).uniq
      states.count == 1 ? states.first : 'mixed'
    end

    # Everything the torrent holds (video and extras, plus anything
    # extracted next to them), or the library file.
    def size
      return items.inject(0) { |sum, i| sum + i.size.to_i } unless torrent

      torrent['total_size'].to_i + items.inject(0) { |sum, i| sum + (i.extracted ? i.size.to_i : 0) }
    end

    # Bytes removing the torrent with its data would free: everything it
    # holds except the video that the library hardlinks.
    def frees_if_removed
      return 0 unless torrent && torrent['complete']

      shared = items.inject(0) { |sum, i| sum + (i.link == 'hardlink' ? i.size.to_i : 0) }
      [size - shared, 0].max
    end

    def fragile?
      items.any?(&:library_depends_on_download?)
    end

    def when
      return Time.at(torrent['done_at']) if torrent && torrent['done_at'].to_i.positive?
      return Time.at(torrent['added_at']) if torrent && torrent['added_at'].to_i.positive?

      items.map(&:mtime).compact.max
    end

    def to_h
      { 'name' => name, 'kind' => kind, 'state' => state, 'size' => size, 'frees_if_removed' => frees_if_removed,
        'fragile' => fragile?, 'when' => self.when && self.when.iso8601, 'torrent' => torrent, 'items' => items.map(&:to_h) }
    end
  end

  # The scan. Everything is gathered in the constructor so the page, the
  # text view and the JSON all describe the same moment.
  class Inventory
    attr_reader :groups, :items, :generated_at, :rpc_error, :media_root, :nas_root, :library_errors

    def initialize(rpc: TransmissionRPC.from_config, log: TransferLog.new, media_root: MediaConfig::MEDIA_ROOT,
                   nas_root: MediaConfig::NAS_ROOT, now: Time.now, nas_check: nil)
      @media_root = media_root
      @nas_root = nas_root
      @generated_at = now
      @nas_check = nas_check || method(:nas_file_exists?)
      @library_errors = []
      @rpc_error = nil
      records = log.records(limit: 5000)
      @records_by_hash = records_by_hash(records)
      @promotions = promotions(records)

      library = scan_library
      @by_inode = {}
      @by_target = {}
      @by_name = {}
      library.values.each do |lib|
        if lib.target
          (@by_target[lib.target] ||= []) << lib
        else
          (@by_inode[[lib.dev, lib.ino]] ||= []) << lib
          (@by_name[File.basename(lib.path)] ||= []) << lib
        end
      end
      torrents = fetch_torrents(rpc)
      @groups = torrents.map { |t| torrent_group(t) }.compact
      @groups += library.values.reject(&:claimed).map { |lib| Group.new(nil, [library_only_item(lib)]) }
      @groups.sort_by! { |g| [-(g.when || Time.at(0)).to_i, g.name.to_s] }
      @items = @groups.flat_map(&:items)
    end

    LibraryFile = Struct.new(:path, :kind, :size, :dev, :ino, :nlink, :target, :mtime, :broken) do
      attr_accessor :claimed
    end

    def totals
      counts = Hash.new(0)
      @items.each { |i| counts[i.state] += 1 }
      library_items = @items.select(&:in_library?)
      torrent_groups = @groups.select(&:torrent)
      complete = torrent_groups.select { |g| g.torrent['complete'] }
      {
        'library_bytes' => library_items.inject(0) { |s, i| s + (i.link == 'copy' ? i.library_size.to_i : i.size.to_i) },
        'library_files' => library_items.count,
        'torrent_bytes' => torrent_groups.inject(0) { |s, g| s + g.size },
        'torrents' => torrent_groups.count,
        'seeding' => torrent_groups.count { |g| g.torrent['seeding'] },
        'shared_bytes' => @items.inject(0) { |s, i| s + (i.link == 'hardlink' ? i.size.to_i : 0) },
        'reclaimable_bytes' => complete.reject(&:fragile?).inject(0) { |s, g| s + g.frees_if_removed },
        'reclaimable_torrents' => complete.reject(&:fragile?).count { |g| g.frees_if_removed.positive? },
        'on_nas' => @items.count(&:on_nas?),
        'warnings' => @items.count { |i| !i.warnings.empty? },
        'states' => counts
      }
    end

    def to_h
      {
        'generated_at' => @generated_at.iso8601,
        'media_root' => @media_root,
        'nas_root' => @nas_root,
        'rpc_error' => @rpc_error,
        'library_errors' => @library_errors,
        'totals' => totals,
        'groups' => @groups.map(&:to_h)
      }
    end

    private

    # ---- the library ------------------------------------------------------

    # Every video file under ~/Media/tv and ~/Media/movies, keyed by path.
    def scan_library
      files = {}
      LIBRARY_KINDS.each do |folder, kind|
        dir = File.join(@media_root, folder)
        next unless File.directory?(dir)

        Dir.chdir(dir) { Dir.glob('**/*') }.sort.each do |rel|
          path = File.join(dir, rel)
          next if File.basename(path).start_with?('.')
          next unless video_name?(path)

          lib = library_file(path, kind)
          files[path] = lib if lib
        end
      end
      files
    rescue SystemCallError => e
      @library_errors << "#{e.class}: #{e.message}"
      files
    end

    def library_file(path, kind)
      lstat = File.lstat(path)
      if lstat.symlink?
        target = File.expand_path(File.readlink(path), File.dirname(path))
        begin
          stat = File.stat(path)
          LibraryFile.new(path, kind, stat.size, stat.dev, stat.ino, stat.nlink, target, stat.mtime, false)
        rescue SystemCallError
          # Unreachable target: broken, unless it points at the NAS, which is simply not mounted.
          LibraryFile.new(path, kind, 0, nil, nil, 0, target, lstat.mtime, !target.start_with?("#{@nas_root}/"))
        end
      elsif lstat.file?
        LibraryFile.new(path, kind, lstat.size, lstat.dev, lstat.ino, lstat.nlink, nil, lstat.mtime, false)
      end
    rescue SystemCallError => e
      @library_errors << "#{path}: #{e.message}"
      nil
    end

    def library_only_item(lib)
      item = Item.new
      item.name = File.basename(lib.path)
      item.kind = lib.kind
      item.size = lib.size
      item.library_path = lib.path
      item.mtime = lib.mtime
      item.on_disk = !lib.broken
      item.link = lib.target ? 'symlink' : nil
      item.nas = nas_for(item.name, lib)
      if lib.broken
        item.warnings << "Broken symlink to #{lib.target}"
      elsif lib.target && lib.target.start_with?("#{@nas_root}/")
        # A --keep-link promotion; the bytes are on the NAS.
      elsif lib.target
        item.warnings << "Symlink to #{lib.target}, which is not in Transmission"
      elsif lib.nlink.to_i > 1
        item.warnings << 'Hardlinked to a file outside Transmission (the download folder, perhaps)'
      end
      item
    end

    # ---- Transmission -----------------------------------------------------

    def fetch_torrents(rpc)
      rpc.torrents(fields: TORRENT_FIELDS)
    rescue TransmissionRPC::Error => e
      @rpc_error = e.message
      []
    end

    # nil when the torrent holds no video (books, music, ...).
    def torrent_group(t)
      dir = t['downloadDir'].to_s
      declared = Array(t['files']).map { |f| [File.join(dir, f['name'].to_s), f] }
      videos = declared.select { |path, _f| video_name?(path) }
      extracted = extracted_videos(t, dir, declared.map(&:first))
      return nil if videos.empty? && extracted.empty?

      record = @records_by_hash[t['hashString'].to_s.downcase]
      torrent = torrent_summary(t, record)
      items = videos.map { |path, f| torrent_item(path, f, torrent, false) } +
              extracted.map { |path| torrent_item(path, nil, torrent, true) }
      kind = torrent_kind(t, record, items)
      items.each { |i| i.kind ||= kind }
      Group.new(torrent, items)
    end

    def torrent_summary(t, record)
      status = t['status'].to_i
      complete = t['percentDone'].to_f >= 1.0 || t['isFinished'] == true
      {
        'hash' => t['hashString'], 'id' => t['id'], 'name' => t['name'], 'download_dir' => t['downloadDir'],
        'status' => TransmissionRPC.status_name(status), 'seeding' => [5, 6].include?(status),
        'stopped' => status.zero?, 'complete' => complete, 'percent' => (t['percentDone'].to_f * 100).round,
        'ratio' => t['uploadRatio'].to_f.round(2), 'total_size' => t['totalSize'].to_i,
        'done_at' => t['doneDate'].to_i, 'added_at' => t['addedDate'].to_i,
        'error' => t['errorString'].to_s.empty? ? nil : t['errorString'],
        'outcome' => record && record['outcome'], 'filed_at' => record && record['ts']
      }
    end

    # Videos inside the torrent's folder that the torrent does not declare:
    # what torrent-finished.rb extracted from an archive.
    def extracted_videos(t, dir, declared_paths)
      return [] if dir.empty? || t['name'].to_s.empty?

      torrent = Torrent.new(t['name'], dir)
      return [] unless File.directory?(torrent.path)

      known = Set.new(declared_paths)
      torrent.files.select { |f| video_name?(f) && !known.include?(f) }
    rescue SystemCallError
      []
    end

    def torrent_item(path, declared, torrent, extracted)
      item = Item.new
      item.name = File.basename(path)
      item.download_path = path
      item.torrent = torrent
      item.extracted = extracted
      stat = begin
        File.stat(path)
      rescue SystemCallError
        nil
      end
      item.on_disk = !stat.nil?
      item.size = stat ? stat.size : declared && declared['length'].to_i
      item.mtime = stat && stat.mtime
      item.warnings << 'Not on disk (moved or deleted outside Transmission)' if stat.nil? && torrent['complete']
      match_library(item, stat)
      item.nas = nas_for(item.name, nil)
      item
    end

    # The library file for a download: same inode (hardlink), a symlink to
    # it, or failing both a file of the same name (a separate copy).
    def match_library(item, stat)
      lib = nil
      if stat
        lib = unclaimed(@by_inode[[stat.dev, stat.ino]])
        item.link = 'hardlink' if lib
      end
      unless lib
        lib = unclaimed(@by_target[item.download_path])
        if lib
          item.link = 'symlink'
          item.warnings << 'Library entry is a symlink into the downloads: removing the torrent data would break it'
        end
      end
      unless lib
        lib = unclaimed(@by_name[item.name])
        if lib
          item.link = 'copy'
          item.library_size = lib.size
          item.warnings << "Separate copy in the library (#{TransferDashboard.size_label(lib.size)} stored twice)"
        end
      end
      return unless lib

      lib.claimed = true
      item.library_path = lib.path
      item.kind = lib.kind
    end

    def unclaimed(candidates)
      (candidates || []).find { |l| !l.claimed }
    end

    def torrent_kind(t, record, items)
      return record['outcome'] if record && LIBRARY_KINDS.values.include?(record['outcome'])

      kinds = items.map(&:kind).compact.uniq
      return kinds.first if kinds.count == 1

      names = [t['name'].to_s] + items.map(&:name)
      return 'tv' if names.any? { |n| EpisodeID.from_release(n) }
      return 'movie' if names.any? { |n| MovieID.from_release(n) }

      'unknown'
    end

    # ---- the NAS, from the log --------------------------------------------

    def records_by_hash(records)
      by_hash = {}
      records.each do |r|
        hash = (r['torrent'] || {})['hash'].to_s.downcase
        next if hash.empty? || r['action'] == 'promote'

        by_hash[hash] ||= r # newest first
      end
      by_hash
    end

    # basename => the promotion record's target and time.
    def promotions(records)
      promoted = {}
      records.each do |r|
        next unless r['action'] == 'promote' && r['status'] == 'ok'

        targets = r['destinations'] || [r['destination']]
        Array(targets).compact.each { |path| promoted[File.basename(path)] ||= { 'path' => path, 'promoted_at' => r['ts'] } }
      end
      promoted
    end

    def nas_for(name, lib)
      if lib && lib.target && lib.target.start_with?("#{@nas_root}/")
        return { 'path' => lib.target, 'promoted_at' => nil, 'verified' => @nas_check.call(lib.target) }
      end

      promotion = @promotions[name]
      return nil unless promotion

      promotion.merge('verified' => @nas_check.call(promotion['path']))
    end

    # true/false when the NAS is mounted, nil when it is not (unknown).
    def nas_file_exists?(path)
      info = TransferDashboard::DiskSpace.for(@nas_root)
      return nil unless info && File.realpath(info['mount']) == File.realpath(@nas_root)

      File.exist?(path)
    rescue SystemCallError
      nil
    end

    def video_name?(path)
      name = File.basename(path).downcase
      return false if MediaFile::BLACKLIST.any? { |term| name.include?(term) }

      MediaFile::EXTENSIONS.include?(File.extname(name))
    end
  end
end
