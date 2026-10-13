# frozen_string_literal: true

require 'fileutils'
require 'set'
require_relative 'torrent_handler'
require_relative 'transfer_dashboard'

# Moves an item from the local library to the NAS: copy, verify, then remove
# the local name. Because the local library is hardlinks into the downloads,
# removing the library name leaves the torrent's copy where it is, still
# seeding. A symlink is removed the same way; a plain file (no other links)
# is a true move.
class Promoter
  class NotMounted < StandardError; end

  def initialize(nas_root:, media_root:, logger:, mounted: nil)
    @nas_root = nas_root
    @media_root = media_root
    @log = logger
    @mounted = mounted
  end

  # The NAS is a separate mount at nas_root; a leftover empty directory at
  # that path (the volume not mounted) must never be written into.
  def mounted?
    return @mounted.call if @mounted

    info = TransferDashboard::DiskSpace.for(@nas_root)
    !info.nil? && File.realpath(info['mount']) == File.realpath(@nas_root)
  rescue StandardError
    false
  end

  # Library files a transfer record filed, verified to still be there. For a
  # set (destination is a directory) the files are found by identity with the
  # torrent's media files, since the record does not list them.
  def library_files(record)
    destination = record['destination'].to_s
    return [] if destination.empty?
    return [destination] if File.file?(destination) || File.symlink?(destination)
    return [] unless File.directory?(destination)

    source_dir = record['media_file'].to_s
    return [] unless File.directory?(source_dir)

    Torrent.new(File.basename(source_dir), File.dirname(source_dir)).files
           .select { |f| MediaFile.valid?(f) }
           .map { |f| File.join(destination, File.basename(f)) }
           .select { |candidate| same_file?(candidate, source_dir) }
  end

  # Promotes every library file of a record. Returns the per-file results.
  def promote_record(record, keep_link: false)
    files = library_files(record)
    raise "Nothing to promote: no library file found for #{record['destination'].inspect}" if files.empty?

    files.map { |f| promote(f, keep_link: keep_link) }
  end

  # Promotes one library file. Returns a result hash.
  def promote(path, keep_link: false)
    raise NotMounted, "NAS is not mounted at #{@nas_root}" unless mounted?
    raise "#{path} is not under #{@media_root}" unless path.start_with?("#{@media_root}/")
    raise "#{path} does not exist" unless File.exist?(path)

    target = File.join(@nas_root, path[(@media_root.length + 1)..-1])
    source = File.realpath(path) # the bytes, whichever name they are reached by
    size = File.size(source)
    FileUtils.mkdir_p(File.dirname(target))

    if File.file?(target) && File.size(target) == size
      @log.info "Already on the NAS: #{target}"
    else
      tmp = "#{target}.copying"
      FileUtils.rm_f(tmp)
      @log.info "Copying #{source} to #{target} (#{size} bytes)"
      FileUtils.cp(source, tmp)
      copied = File.size(tmp)
      raise "Copy incomplete: #{copied} of #{size} bytes at #{tmp}" unless copied == size

      File.rename(tmp, target)
      @log.info 'Copy complete'
    end

    was_symlink = File.symlink?(path)
    links = was_symlink ? nil : File.stat(path).nlink
    File.unlink(path)
    still_seeding = was_symlink || (links && links > 1)
    @log.info "Removed local #{was_symlink ? 'symlink' : 'copy'} #{path}#{still_seeding ? ' (download copy untouched)' : ''}"
    if keep_link
      File.symlink(target, path)
      @log.info "Left a symlink to the NAS at #{path}"
    end

    { 'source' => path, 'target' => target, 'bytes' => size, 'still_seeding' => !!still_seeding, 'kept_link' => keep_link }
  end

  private

  def same_file?(candidate, source_dir)
    return false unless File.exist?(candidate) || File.symlink?(candidate)
    return File.readlink(candidate).start_with?("#{source_dir}/") if File.symlink?(candidate)

    Dir.glob(File.join(source_dir, '**', '*')).any? { |f| File.file?(f) && File.identical?(f, candidate) }
  end
end
