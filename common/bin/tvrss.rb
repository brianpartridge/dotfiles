#!/usr/bin/env ruby

require_relative 'lib/episode_id'
require_relative 'lib/feed_cache'
require 'json'
require 'rss'
require 'uri'
require_relative 'lib/utils'

$conf_filename = "tvrss.json"
$dl_dir = '~/Dropbox/torrents/'

def load_config
  load_json_config($conf_filename)
end

def save_config(hash)
  save_json_config($conf_filename, hash)
end

def dl_item_path(ep)
    File.expand_path($dl_dir + ep.title + '.torrent')
end

def download_ep(ep)
    download(ep.link, ep.title, dl_item_path(ep))
end

def update_series_for_ep(series_dict, ep)
  series_dict['season'] = ep.season
  series_dict['episode'] = ep.episode
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
    last_seen_ep = ConfigEpisode.new(series_dict)
    
    @feed_cache.items_for_feed(feed_name)
      .select { |i| keywords.map(&:downcase).reduce(true) { |memo, k| memo && i.title.downcase.include?(k) } }
      .map { |i| FeedEpisode.from_feed_item(i) }
      .reject { |i| i.nil? }
      .select { |e| e.id > last_seen_ep.id }
  end
    
end

# Abstract model for S#E#-based episodes
class Episode
  attr_reader :id
  def initialize(id)
    @id = id
  end
end

# An episode loaded from a feed
class FeedEpisode<Episode
  attr_reader :title, :link
  def initialize(id, title, link)
    super(id)
    @title = title
    @link = link
  end

  def self.from_feed_item(feed_item)
    id = EpisodeID.from_release(feed_item.title)
    return nil unless id
    FeedEpisode.new(id, feed_item.title, feed_item.link)
  end
end

# An episode loaded from a config file
class ConfigEpisode<Episode
  attr_reader :title
  def initialize(series_dict)
    super(EpisodeID.new(series_dict['season'], series_dict['episode']))
    @title = series_dict['keywords']
  end
end

def run!
  config = load_config
  cache = FeedCache.new(config['feeds'])
  processor = FeedProcessor.new(cache)
  
  modified = false
  config['series'].each do |s|
    last_seen = ConfigEpisode.new(s)
    info "Checking '#{s['keywords']}' newer than #{last_seen.id.to_s}..."
    sorted_eps = processor.episodes_for_series(s).sort { |l,r| l.id < r.id }
    next if sorted_eps.empty?
    
    eps = sorted_eps.uniq { |ep| ep.id }
    info "Found #{sorted_eps.count} candidates, downloading #{eps.count}..."
    eps.each { |e| download_ep(e) }
    
    update_series_for_ep(s, eps.last)
    modified = true
  end
  
  save_config(config) if modified
  success 'Done'
end

run!
