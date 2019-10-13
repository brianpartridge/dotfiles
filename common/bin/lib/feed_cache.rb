# frozen_string_literal: true

require 'rss'
require 'uri'
require_relative 'utils'

# Handles loading feed content and caching it for the duration of the process.
# feed_dicts is an array of hashes with keys: 'name' (must be unique), 'url', and 'passkey_file' (optional)
class FeedCache
  def initialize(feed_dicts)
    @feed_dict_by_name = feed_dicts.map { |f| [f['name'], f] }.to_h
    @cache = {}
  end

  def items_for_feed(feed_name)
    return @cache[feed_name] if @cache.key? feed_name

    feed_dict = @feed_dict_by_name[feed_name]
    if feed_dict.nil?
      @cache[feed_name] = []
    else
      url = authenticated_url(feed_dict['url'], feed_dict['passkey_file'])
      feed = nil
      begin
        fd = open(url)
        data = fd.read
        feed = RSS::Parser.parse(data)
      rescue Exception => e
        error "#{e.message} : #{e.backtrace.inspect}"
        fatal "Unable to fetch #{feed_name} : #{e.message}"
      end
      @cache[feed_name] = feed.nil? ? [] : feed.items
      info2 "Loaded #{@cache[feed_name].count} items for #{feed_name}"
      # feed.items.each { |i| debug "Item: #{i.title}" }
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
