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

def download_ep(ep)
    download(ep.link, ep.title, $dl_dir, "#{ep.title}.torrent")
end

def update_series_for_ep(series_dict, ep)
  series_dict['season'] = ep.id.season
  series_dict['episode'] = ep.id.episode
end

# Processes a feed of items into episodes based on a series dictionary.
class FeedProcessor
  def initialize(feed_cache)
    @feed_cache = feed_cache
  end

  # All episode matching series keywords from the first series feed with matches.
  def series_episodes(series_dict)
    episodes_for_series(series_dict)
  end

  # All series_episodes which are new.
  def candidate_episodes(series_dict)
    last_seen_ep = ConfigEpisode.new(series_dict)
    series_episodes(series_dict).select { |e| e.id > last_seen_ep.id }
  end 
 
  # Private

  def episodes_for_series(series_dict)
    eps = episodes_for_series_in_feed(series_dict, series_dict['feed'])
    return eps if eps.count > 0
    
    return episodes_for_series_in_feed(series_dict, series_dict['fallback'])
  end
  
  def episodes_for_series_in_feed(series_dict, feed_name)
    keywords = series_dict['keywords'].split(' ')
    @feed_cache.items_for_feed(feed_name)
      .select { |i| keywords.map(&:downcase).reduce(true) { |memo, k| memo && i.title.downcase.include?(k) } }
      .map { |i| FeedEpisode.from_feed_item(i) }
      .reject { |i| i.nil? }
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
    series_eps = processor.series_episodes(s)
    series_eps.each { |e| debug "Match: #{e.title}" }

    candidate_eps = processor.candidate_episodes(s)
    candidate_eps.each { |e| debug "Candidate: #{e.title}" }
    
    eps = candidate_eps.sort { |l, r| l.id <=> r.id }
      .uniq { |e| e.id }
    
    info "Found #{series_eps.count} series matches, #{candidate_eps.count} candidates, #{eps.count} new..." if series_eps.count > 0 || candidate_eps.count > 0
    next if eps.empty?

    eps.each { |e| download_ep(e) }
    
    update_series_for_ep(s, eps.last)
    modified = true
  end
  
  save_config(config) if modified
  success 'Done'
end

run!
