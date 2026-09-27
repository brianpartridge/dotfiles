#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-time conversion of the symlinks torrent-finished.rb used to leave in the
# media library into hardlinks, so that removing a torrent's data no longer
# removes the item from Plex. Safe to re-run; dry run unless --apply.
#
#   media-hardlinks.rb                 # report what would change under the default directories
#   media-hardlinks.rb --apply         # do it
#   media-hardlinks.rb --apply DIR...  # other directories

require 'optparse'

DEFAULT_DIRS = ['/Users/theater/Media/tv', '/Users/theater/Media/movies'].freeze

apply = false
OptionParser.new do |opts|
  opts.banner = 'Usage: media-hardlinks.rb [--apply] [DIR ...]'
  opts.on('--apply', 'Replace symlinks with hardlinks (default is a dry run)') { apply = true }
  opts.on('-h', '--help') { puts opts; exit }
end.parse!
dirs = ARGV.empty? ? DEFAULT_DIRS : ARGV

counts = Hash.new(0)
dirs.each do |dir|
  unless File.directory?(dir)
    puts "skip     #{dir}: not a directory"
    next
  end
  Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH).sort.each do |link|
    next unless File.symlink?(link)

    target = File.expand_path(File.readlink(link), File.dirname(link))
    unless File.file?(target)
      puts "dangling #{link} -> #{target}"
      counts[:dangling] += 1
      next
    end
    if File.stat(target).dev != File.stat(File.dirname(link)).dev
      puts "volume   #{link}: target is on a different volume, leaving the symlink"
      counts[:other_volume] += 1
      next
    end

    if apply
      tmp = "#{link}.linking"
      File.unlink(tmp) if File.symlink?(tmp) || File.exist?(tmp)
      File.link(target, tmp)
      File.rename(tmp, link) # atomically replaces the symlink
      puts "linked   #{link}"
    else
      puts "would    #{link} -> #{target}"
    end
    counts[:converted] += 1
  end
end

verb = apply ? 'converted' : 'would convert'
puts "#{verb} #{counts[:converted]}, dangling #{counts[:dangling]}, other volume #{counts[:other_volume]}"
puts 'Dry run: re-run with --apply to make the change.' unless apply
exit(counts[:dangling].zero? ? 0 : 2)
