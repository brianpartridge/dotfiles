#!/usr/bin/ruby

# Profile
# https://letterboxd.com/brianpartridge/
# Activity
# https://letterboxd.com/brianpartridge/activity/
# Watchlist
# https://letterboxd.com/brianpartridge/watchlist/
# RSS
# https://letterboxd.com/brianpartridge/rss/
# Film
# https://letterboxd.com/film/harold-and-maude/

# General idea, since we can't get what we need from an RSS feed or API
# - Load watchlist URL, identify elements based on their `data-film-slug` on a div
# - Read cache from disk which lists all of the slugs that have already been processed
# - For new entries:
#   - Load the page
#   - Find the IMDB link and parse the `tt` ID out of the URL
#   - use hdbits.add_to_wishlist to add desired films to HDbits
#   - add slug to in memory cache
# - Write the updated cache back to disk
#
# Out of band tasks:
# - Wire this up to run every couple minutes

class LetterboxdWatchlistEntry
  @slug
  @imdb_id

  attr_reader: slug
  attr_reader: imdb_id
end

base_url = 'https://letterboxd.com'
watchlist_path = '/Users/brianpartridge/Desktop/watchlist.html'
watchlist_url = 'https://letterboxd.com/brianpartridge/watchlist/'

require 'nokogiri'
require 'open-uri'
require 'set'
watchlist_page = Nokogiri::HTML(open(watchlist_path)) #open(watchlist_url))
slugs = Set.new(watchlist_page.css('div.poster').map { |p| p['data-film-slug'] })

cached_slugs = Set.new()
puts "cache: #{cached_slugs.join '\n'}"

new_slugs = slugs.subtract(cached_slugs)
puts "new: #{new_slugs.join '\n'}"

new_entries = new_slugs.flat_map do |s|
  url = base_url
  film_page = Nokogiri::HTML(open(url))
  imdb_url = film_page.css('a[data-track-action=IMDb]').first['href']
  match = imdb_url.match 'title/(tt\d+)/'
  if match.nil?
    nil
  else
    LetterboxdWatchlistEntry.new(s, match[1])
  end
end

new_entries.each do |e|
  puts "ERROR: unable to add #{ i.slug } to wishlist" unless hdbits.add_to_wishlist(e.imdb_id)
end

puts "updated cache: #{cached_slugs.join '\n'}"

# require 'rexml/document'
# include REXML
# xmlfile = File.new(watchlist_path)
# xmldoc = Document.new(xmlfile)
# root = xmldoc
# puts root

# File.open('/Users/brianpartridge/Desktop/watchlist.html', 'r') { |f|
#   f.each_line do |l|
#     puts l
#   end
# }
