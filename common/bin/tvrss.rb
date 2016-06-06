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

def dl_item_path(ep)
    File.expand_path($dl_dir + ep.title + '.torrent')
end

def download_ep(ep)
    success "Downloading #{ep.title}"
    open(dl_item_path(ep), 'wb') do |f|
        f << open(ep.link).read
    end
end

def update_series_for_ep(series_dict, ep)
  series_dict['season'] = ep.season
  series_dict['episode'] = ep.episode
end

def info(message)
  puts '💛  ' + message
end

def success(message)
  puts '💚  ' + message
end

def fatal(message)
  abort '💔  ' + message
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
      success "Loaded #{@cache[feed_name].count} items for #{feed_name}"
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
    last_seen_ep = ConfigEpisode.new(series_dict)
    
    @feed_cache.items_for_feed(feed_name)
      .select { |i| keywords.map(&:downcase).reduce(true) { |memo, k| memo && i.title.downcase.include?(k) } }
      .map { |i| FeedEpisode.new(i) }
      .select { |e| e > last_seen_ep }
  end
    
end

# Model to simplify comparison of S#E#-based episodes
class Episode
  attr_reader :season, :episode
  def initialize(season, episode)
    @season = season.to_i
    @episode = episode.to_i
  end
  
  def title
    nil
  end
  
  def link
    nil
  end
  
  def display
    "S%02iE%02i" % [@season, @episode]
  end
  
  def <(ep)
    (self <=> ep) == -1
  end
  
  def >(ep)
    (self <=> ep) == 1
  end
  
  def ==(ep)
    (self <=> ep) == 0
  end
    
  def <=>(ep)
    if @season < ep.season
      -1
    elsif @season > ep.season
      1
    elsif @episode < ep.episode
      -1
    elsif @episode > ep.episode
      1
    else
      0
    end
  end
  
end

class FeedEpisode<Episode
  def initialize(feed_item)
    sanitized_title = feed_item.title.gsub(/h.264/i, '').gsub(/720p/i, '').gsub(/1080p/i, '')
    m = sanitized_title.match(/^(.+)[\._ \-][Ss]?(\d+)?[\._ \-]?[EeXx]?(\d{2})[\._ \-]/)
    super(m[2], m[3])
    @item = feed_item
  end
  
  def title
    @item.title
  end
  
  def link
    @item.link
  end
end

class ConfigEpisode<Episode
  def initialize(series_dict)
    super(series_dict['season'], series_dict['episode'])
    @series_dict = series_dict
  end
  
  def title
    @series_dict['keywords']
  end
end

def run!
  config = load_config
  cache = FeedCache.new(config['feeds'])
  processor = FeedProcessor.new(cache)
  
  modified = false
  config['series'].each do |s|
    last_seen = ConfigEpisode.new(s)
    info "Checking '#{s['keywords']}' newer than #{last_seen.display}..."
    sorted_eps = processor.episodes_for_series(s).sort
    next if sorted_eps.empty?
    
    eps = sorted_eps.uniq
    info "Found #{sorted_eps.count} candidates, downloading #{eps.count}..."
    eps.each { |e| download_ep(e) }
    
    update_series_for_ep(s, eps.last)
    modified = true
  end
  
  save_config(config) if modified
  success 'Done'
end

run!
