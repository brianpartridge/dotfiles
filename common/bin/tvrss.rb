#!/usr/bin/ruby

require 'json'
require 'rss'
require 'uri'

$conf_dir = '~/Dropbox/conf/'
$conf_filename = "tvrss.json"
$dl_dir = '~/Dropbox/torrents/'

def conf_file(filename)
    File.expand_path($conf_dir + filename)
end

def first_line_from_file(path)
    File.readlines(File.expand_path(path)).first
end

def load_config
  JSON.parse(open(conf_file($conf_filename)).read)
end

def save_config(hash)
  open(conf_file($conf_filename), 'wb') do |f|
    f << JSON.pretty_generate(hash)
  end
end

def dl_item_path(item)
    File.expand_path($dl_dir + item.title + '.torrent')
end

def download_item(item)
    puts "Downloading #{item.title}"
    open(dl_item_path(item), 'wb') do |f|
        f << open(item.link).read
    end
end

# Handles loading feed content and caching it for the duration of the process.
class FeedCache
  def initialize(feed_dicts)
    @feed_dict_by_name = feed_dicts.map { |f| [f['name'], f] }.to_h
    @cache = {}
  end
  
  def items_for_feed(feed_name)
    return @cache[feed_name] if @cache.has_key? feed_name
    
    feed_dict = @feed_dict_by_name[feed_name]
    if feed_dict.nil?
      @cache[feed_name] = []
    else
      url = authenticated_url(feed_dict['url'], feed_dict['passkey_file'])
      feed = RSS::Parser.parse(open(url).read)
      @cache[feed_name] = feed.nil? ? [] : feed.items
    end
    
    @cache[feed_name]
  end
    
  # Private
  
  def authenticated_url(base_url, passkey_filename)
    passkey = first_line_from_file(conf_file(passkey_filename))
    url = URI.parse(base_url)
    url.query = URI.encode_www_form(URI.decode_www_form(url.query) + [['passkey', passkey]])
    url.to_s
  end
  
end

# Processes a feed of items into episodes based on a series dictionary.
class FeedProcessor
  def initialize(feed_cache)
    @feed_cache = feed_cache
  end
  
  def episodes_for_series(series_dict)
    eps = episodes_for_series_in_feed(series_dict, series_dict['feed'])
    return eps if eps.count > 0
    
    return episodes_for_series_in_feed(series_dict, series_dict['fallback'])
  end
  
  # Private
  
  def episodes_for_series_in_feed(series_dict, feed_name)
    keywords = series_dict['keywords'].split(' ')
    last_seen_ep = Episode.episode_with_series_dict(series_dict)
    
    @feed_cache.items_for_feed(feed_name)
      .select { |i| keywords.map(&:downcase).reduce(true) { |memo, k| memo && i.title.downcase.include?(k) } }
      .map { |i| Episode.episode_with_feed_item(i) }
      .select { |e| e > last_seen_ep }
  end
    
end

# Model to simplify comparison of S#E#-based episodes
class Episode
  attr_reader :title, :season, :episode, :link
  def initialize(title, season, episode, link)
    @title = title
    @season = season.to_i
    @episode = episode.to_i
  end
  
  def self.episode_with_feed_item(feed_item)
    sanitized_title = feed_item.title.gsub(/h.264/i, '').gsub(/720p/i, '').gsub(/1080p/i, '')
    m = sanitized_title.match(/^(.+)[\._ \-][Ss]?(\d+)?[\._ \-]?[EeXx]?(\d{2})[\._ \-]/)
    Episode.new(feed_item.title, m[2], m[3], feed_item.link)
  end
  
  def self.episode_with_series_dict(series_dict)
    Episode.new(series_dict['keywords'], series_dict['season'], series_dict['episode'], nil)
  end
  
  def >(ep)
    if @season > ep.season
      true
    elsif @season == ep.season && @episode > ep.episode
      true
    else
      false
    end
  end
  
end

def run!
  config = load_config
  cache = FeedCache.new(config['feeds'])
  processor = FeedProcessor.new(cache)
  
  serieses = config['series']
  serieses.each do |s|
    puts "*** #{s['keywords']}"
    puts "   " + processor.episodes_for_series(s).map(&:title).join(", ")
  end
  
end

run!

