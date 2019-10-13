#!/usr/bin/env ruby
#encoding : utf-8

require_relative 'lib/episode_id'
require 'fileutils'
require 'logger'
require_relative 'lib/movie_id'
require_relative 'lib/tweet'
require 'uri'
require_relative 'lib/utils'

# Configuration
MEDIA_ROOT = "/Users/theater/Media"
TV_DIRECTORY = File.join(MEDIA_ROOT, "tv")
MOVIE_DIRECTORY = File.join(MEDIA_ROOT, "movies")

# DO NOT MODIFY BELOW THIS LINE #

$logger = Logger.new(File.expand_path('~/logs/torrent-finished.log'), 10, 1024000)

class Torrent
  attr_reader :name, :hash, :directory

  def initialize(name, directory)
    @name = name
    @directory = directory
  end

  def self.from_env
    name = ENV['TR_TORRENT_NAME']
    return nil if name.nil? || name.empty? 
    dir = ENV['TR_TORRENT_DIR']
    return nil if dir.nil? || dir.empty?
    Torrent.new(name, dir)
  end

  def files
    download = File.join(@directory, @name)
    if File.directory?(download)
      Dir.entries(download).select { |f| !f.start_with?('.') }.map { |f| File.join(download, f) }
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
    name = @torrent.name
    tweet "SUCCESS:Download #{name}"
    media = @torrent.files.select { |f| File.valid_media_file?(f) }
    if media.empty?
      $logger.info "No media files found for #{name}"
      tweet "WARNING:No Media - #{name}"
    elsif media.count == 1
      path = media.first
      filename = File.basename(path)
      if !EpisodeID.from_release(name).nil?
        $logger.info "Found single episode"
        copy_file(path, TV_DIRECTORY)
        tweet "SUCCESS:TV Show - #{filename}"
      elsif !MovieID.from_release(name).nil?
        $logger.info "Found movie"
        link_file(path, MOVIE_DIRECTORY)
        tweet "SUCCESS:Movie - #{filename}"
      else
        error "Unsupported media #{path}"
        tweet "WARNING:Unknown Media - #{filename}"
      end
    else
      error "Too many media files #{media.count}, unable to determine primary file."
      tweet "WARNING:Multiple Media Files - #{name}"
    end
  end

  def copy_file(path, destination_directory)
    $logger.info "Copying #{path} to #{destination_directory}"
    FileUtils.copy(path, destination_directory)
    $logger.info "Copy complete"
  end

  def link_file(path, destination_directory)
    filename = File.split(path).last
    destination_path = File.join(destination_directory, filename)
    $logger.info "Symlinking  #{path} to #{destination_path}"
    FileUtils.ln_s(path, destination_path)
    $logger.info "Symlinking complete"
  end
end

class File
  def self.valid_media_file?(path)
    file_name = File.basename(path)
    return false if file_name.nil?
    return false unless File.file?(path)

    blacklist = ['sample']
    return false if blacklist.reduce(false) { |acc, term| acc || file_name.include?(term) }

    valid_extensions = ['.mkv', '.avi', '.mov']
    return false unless valid_extensions.include?(File.extname(file_name))

    true
  end
end

class Repro
  def self.cmd
    environment = ENV.keys.select { |k| k.start_with? 'TR_TORRENT_' }.sort.map { |k| "#{k}=\"#{ENV[k]}\"" }.join(' ')
    script = File.expand_path(__FILE__)
    "/usr/bin/env #{environment} ruby #{script}"
  end
end

if __FILE__ == $0
  $logger.info "STARTING: #{Repro.cmd}"

  torrent = Torrent.from_env
  $logger.fatal "ABORTING: No torrent found" unless torrent

  Handler.new(torrent).run!
end

