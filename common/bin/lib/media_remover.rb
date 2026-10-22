# frozen_string_literal: true

require 'fileutils'
require_relative 'media_inventory'
require_relative 'transmission_rpc'

# The media page's destructive actions, done carefully.
#
# Removing a torrent with its data is safe for the library because the
# library is hardlinks: the bytes stay with the library name. A legacy
# symlink into the downloads is turned into a hardlink first (a copy when
# the volumes differ). Library entries are only ever removed when asked,
# and only under the local library root; the NAS is never touched.
class MediaRemover
  SETTLE_SECONDS = 15 # how long to wait for Transmission to delete its files

  def initialize(rpc:, media_root:, logger:, inventory: nil, sleeper: nil)
    @rpc = rpc
    @media_root = media_root
    @log = logger
    @inventory = inventory || lambda { MediaInventory::Inventory.new(rpc: rpc, media_root: media_root) }
    @sleeper = sleeper || lambda { |s| sleep(s) }
  end

  # The inventory group for a torrent, so the worker acts on exactly what
  # the page showed.
  def group_for(hash)
    wanted = hash.to_s.downcase
    group = @inventory.call.groups.find { |g| g.torrent && g.torrent['hash'].to_s.downcase == wanted }
    raise "No torrent with hash #{hash} in Transmission (already removed?)" unless group

    group
  end

  # Removes the torrent and its data. With keep_library (the default) every
  # library entry of the torrent keeps its bytes; without it the local
  # library entries go too. Returns a summary hash.
  def remove_torrent(hash, keep_library: true)
    group = group_for(hash)
    torrent = group.torrent
    raise "#{torrent['name']} is still downloading (#{torrent['percent']}%)" unless torrent['complete']

    kept = []
    removed_library = []
    extra = 0
    group.items.each do |item|
      next unless item.in_library?

      if keep_library
        secure_library_copy(item)
        kept << item.library_path
      else
        unlink_library_file(item.library_path)
        removed_library << item.library_path
        extra += item.size.to_i if item.link == 'hardlink' # the last name is going too
        extra += item.library_size.to_i if item.link == 'copy'
      end
    end
    frees = group.frees_if_removed + extra # after securing: a relinked symlink now counts as shared

    @log.info "Removing #{torrent['name']} from Transmission with its data"
    @rpc.remove([torrent['id']], delete_data: true)
    declared = group.items.reject(&:extracted).map(&:download_path)
    wait_for_deletion(declared)
    tidy_download_dir(group)

    {
      'torrent' => torrent['name'], 'hash' => torrent['hash'], 'freed' => frees,
      'kept' => kept, 'removed_library' => removed_library, 'ratio' => torrent['ratio']
    }
  end

  # Removes the local library entries of a torrent (bytes stay with the
  # download and the NAS), or one library file given by path.
  def unlink_library(hash: nil, path: nil)
    paths = if path
              [File.expand_path(path)]
            else
              group_for(hash).items.select(&:in_library?).map(&:library_path)
            end
    raise 'Nothing in the local library to remove' if paths.empty?

    paths.each { |p| unlink_library_file(p) }
    { 'removed_library' => paths }
  end

  private

  # A symlink into the downloads would dangle once the download goes;
  # replace it with a hardlink (or a copy across volumes), atomically.
  def secure_library_copy(item)
    return unless item.library_depends_on_download?

    source = File.realpath(item.library_path)
    target = item.library_path
    tmp = "#{target}.relinking"
    FileUtils.rm_f(tmp)
    begin
      File.link(source, tmp)
      @log.info "Replaced symlink #{target} with a hardlink"
    rescue Errno::EXDEV
      @log.info "Copying #{source} to #{target} (different volume)"
      FileUtils.cp(source, tmp)
      raise "Copy incomplete at #{tmp}" unless File.size(tmp) == File.size(source)
    end
    File.rename(tmp, target)
    item.link = 'hardlink'
  end

  def unlink_library_file(path)
    raise "#{path} is not under #{@media_root}" unless path.start_with?("#{@media_root}/")
    raise "#{path} does not exist" unless File.exist?(path) || File.symlink?(path)

    File.unlink(path)
    @log.info "Removed #{path} from the library"
  end

  def wait_for_deletion(paths)
    deadline = Time.now + SETTLE_SECONDS
    loop do
      remaining = paths.select { |p| File.exist?(p) }
      return if remaining.empty?
      if Time.now >= deadline
        @log.warn "Transmission has not deleted #{remaining.count} file(s) yet: #{remaining.first}"
        return
      end

      @sleeper.call(0.5)
    end
  end

  # What Transmission leaves behind: files it never knew about (extracted
  # videos), then any folders that are now empty, the torrent's own included.
  def tidy_download_dir(group)
    group.items.select(&:extracted).each do |item|
      next unless File.exist?(item.download_path)

      File.unlink(item.download_path)
      @log.info "Removed extracted #{item.download_path}"
    end
    dir = File.join(group.torrent['download_dir'].to_s, group.torrent['name'].to_s)
    return unless File.directory?(dir) && !File.symlink?(dir)

    if remove_if_empty(dir)
      @log.info "Removed empty #{dir}"
    else
      @log.info "Left #{dir} in place: other files remain"
    end
  rescue SystemCallError => e
    @log.warn "Could not tidy #{dir}: #{e.message}"
  end

  # Removes a directory tree that holds nothing but .DS_Store files. Returns
  # whether it was removed.
  def remove_if_empty(dir)
    entries = Dir.entries(dir) - %w[. ..]
    entries.each do |e|
      sub = File.join(dir, e)
      remove_if_empty(sub) if File.directory?(sub) && !File.symlink?(sub)
    end
    remaining = Dir.entries(dir) - %w[. .. .DS_Store]
    return false unless remaining.empty?

    FileUtils.rm_f(File.join(dir, '.DS_Store'))
    Dir.rmdir(dir)
    true
  end
end
