#!/usr/bin/env ruby
#encoding : utf-8

require_relative 'lib/episode_id'
require_relative 'lib/movie_id'
require_relative 'lib/tweet'
require 'uri'
require_relative 'lib/utils'

# Configuration
MEDIA_ROOT = "/Users/theater/Media"
TV_DIRECTORY = File.join(MEDIA_ROOT, "tv")
MOVIE_DIRECTORY = File.join(MEDIA_ROOT, "movies")

# DO NOT MODIFY BELOW THIS LINE #

class Torrent
  attr_reader :name, :hash, :directory

  def initialize(name, directory)
    @name = name
    @directory = directory
  end

  def self.from_env
    name = ENV['TR_TORRENT_NAME']
    return nil if name.nil? || name.empty? 
    dir = ENV['TR_TORRENT_DIRECTORY']
    return nil if dir.nil? || dir.empty?
    Torrent.new(name, dir)
  end

  def files
    download = File.join(@directory, @name)
    if File.directory?(download)
      Dir.entries(download).filter { |f| !f.start_with('.') }.map { |f| File.join(@directory, f) }
    else
      [download]
    end
  end
end

class Handler
  def initialize(torrent)
    @torrent = torrent
  end

  def run!
    media = @torrent.files.select { |f| File.valid_media_file?(f) }
    if media.empty?
      info "No media files found for #{@torrent.name}"
    elsif media.count == 1
      if EpisodeID.from_release(@torrent.name) != nil
        info "Found single episode"
      elsif MovieID.from_release(@torrent.name) != nil
        info "Found movie"
      else
        error "Unsupported media #{media.first}"
      end
    else
      error "Too many media files #{media.count}, unable to determine primary file."
    end
  end
end

class File
  def valid_media_file?(file_name_or_path)
    file_name = File.basename(file_name)
    return false if file_name.nil?
    return false unless File.file?(file_name)

    blacklist = ['sample']
    return false if blacklist.reduce(false) { |term| file_name.include?(term) }

    valid_extension = ['.mkv', '.avi', '.mov']
    return false unless valid_extensions.include?(File.extname(file_name))

    true
  end
end

if __FILE__ == $0
  torrent = Torrent.from_env
  bail "No torrent found" if torrent.nil?

  handler = Handler.new(torrent)
  handler.run!
end

