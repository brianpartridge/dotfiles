#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/episode_id'
require_relative 'lib/feed_cache'
require 'json'
require 'rss'
require_relative 'lib/tweet'
require 'uri'
require_relative 'lib/utils'

$conf_filename = 'tvrss.json'
$dl_dir = '~/Dropbox/torrents/'

def load_config
  load_json_config($conf_filename)
end

def save_config(hash)
  save_json_config($conf_filename, hash)
end

# Identifies episodes in the feed cache for a given series.
class SeriesProcessor
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

    episodes_for_series_in_feed(series_dict, series_dict['fallback'])
  end

  def episodes_for_series_in_feed(series_dict, feed_name)
    keywords = series_dict['keywords'].split(' ').map(&:downcase)
    blacklist = series_dict['blacklist'].to_s.split(' ').map(&:downcase)
    @feed_cache.items_for_feed(feed_name)
               .select { |i| keywords.reduce(true) { |memo, k| memo && i.title.downcase.include?(k) } }
               .select { |i| blacklist.reduce(true) { |memo, k| memo && !i.title.downcase.include?(k) } }
               .map { |i| FeedEpisode.from_feed_item(i) }
               .reject(&:nil?)
  end
end

# An episode loaded from a feed
class FeedEpisode
  attr_reader :id, :title, :link
  def initialize(id, title, link)
    @id = id
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
class ConfigEpisode
  attr_reader :id, :title
  def initialize(series_dict)
    @id = EpisodeID.new(series_dict['season'], series_dict['episode'])
    @title = series_dict['keywords']
  end
end

class TVRSS
  def initialize(config, processor)
    @config = config.clone
    @processor = processor
  end

  def download_updates!
    @config['series'].each { |s| process_series(s) }
    @config
  end

  def process_series(series_dict)
    eps = fresh_eps_for_series(series_dict)
    return if eps.empty?

    eps.each { |e| download_ep(e) }
    update_series(series_dict, eps.last)
  end

  def fresh_eps_for_series(series_dict)
    last_seen = ConfigEpisode.new(series_dict)
    info "Checking '#{series_dict['keywords']}' newer than #{last_seen.id}..."

    series_eps = @processor.series_episodes(series_dict)
    series_eps.each { |e| info2 "Match: #{e.title}" }

    candidate_eps = @processor.candidate_episodes(series_dict)
    candidate_eps.each { |e| info2 "Candidate: #{e.title}" }

    fresh_eps = candidate_eps.sort { |l, r| l.id <=> r.id }.uniq(&:id)
    if series_eps.count > 0 || candidate_eps.count > 0
      info "Found #{series_eps.count} series matches, #{candidate_eps.count} candidates, #{fresh_eps.count} new..."
    end

    fresh_eps
  end

  def download_ep(ep)
    tweet "START:Download - #{ep.title}"
    download(ep.link, ep.title, $dl_dir, "#{ep.title}.torrent")
  end

  def update_series(series_dict, latest_ep)
    series_dict['season'] = latest_ep.id.season
    series_dict['episode'] = latest_ep.id.episode
  end
end

def run!
  config = load_config
  cache = FeedCache.new(config['feeds'])
  processor = SeriesProcessor.new(cache)
  new_config = TVRSS.new(config, processor).download_updates!

  save_config(config) # unless config == new_config
  success 'Done'
end

run!
