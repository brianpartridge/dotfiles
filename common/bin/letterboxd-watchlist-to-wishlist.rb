#!/usr/bin/env ruby
#encoding : utf-8

# Install HDBits from https://github.com/brianpartridge/HDBits
require 'hdbits'
require 'logger'
require 'nokogiri'
require 'open-uri'
require 'set'

$conf_dir = '~/Dropbox/conf/'

$logger = Logger.new(File.expand_path('~/logs/letterboxd-watchlist-to-wishlist.log'), 10, 1024000)

def info(msg)
    puts msg
    $logger.info msg
end

def warn(msg)
    puts msg
    $logger.warn msg
end

def error(msg)
    puts msg
    $logger.error msg
end

class LetterboxdWatchlist
  @url
  @items

  attr_reader :url
  attr_reader :items

  def initialize(url)
    @url = url

    watchlist_page = Nokogiri::HTML(open(url))
    @items = watchlist_page
      .css('div.poster')
      .map { |p| p['data-film-slug'] }
      .map { |s| Item.new(s) }
  end

  def to_s
    "#{url} - #{items.count} Items"
  end

  class Item
    @slug
    @id

    attr_reader :slug
    attr_reader :id

    def initialize(slug)
      @slug = slug
    end

    def url
      URI('https://letterboxd.com' + slug)
    end

    def fetch_id
      film_page = Nokogiri::HTML(open(url))
      imdb_url = film_page.css('a[data-track-action=IMDb]').first['href']
      match = imdb_url.match 'title/(tt\d+)/'
      @id = match[1] unless match.nil?
    end

    def to_s
      "#{slug} - #{id}"
    end
  end
end

def conf_file(filename)
    File.expand_path($conf_dir + filename)
end

def all_lines_from_file(path)
    File.readlines(File.expand_path(path)).map(&:strip)
end

def first_line_from_file(path)
    all_lines_from_file(path).first
end

def load_watchlist_ids(watchlist_items)
    watchlist_items.each do |i| 
        return unless i.id.nil?

        info "Fetching id for #{i.slug}"

        i.fetch_id 

        # Add a delay so we don't hammer the server.
        sleep 2
    end
end

def ids_not_on_wishlist(watchlist_items, wishlist_items)
    watchlist_ids = Set.new(watchlist_items.map(&:id))

    wishlist_ids = Set.new(wishlist_items.map { |i|
        # Pad to 7 digits and add the 'tt' prefix.
        "tt#{ i.imdb.to_s.rjust(7, '0') }"
    })

    watchlist_ids.subtract(wishlist_ids)
end

def new_hdbits
    user = first_line_from_file(conf_file('hdbits-username'))
    passkey = first_line_from_file(conf_file('hdbits-passkey'))
    HDBits.new(user, passkey)
end

def new_watchlist
    watchlist_url = first_line_from_file(conf_file('letterboxd-watchlist-url'))
    LetterboxdWatchlist.new(watchlist_url)
end

def load_watchlist_cache
    path = conf_file('letterboxd-watchlist-cache')
    return Set.new() unless File.exists? path
    all_lines_from_file(path).to_set
end

def save_watchlist_cache(slugs)
    path = conf_file('letterboxd-watchlist-cache')
    # The double quote around \n is important here, single quotes will insert a literal \n not a new line.
    File.open(path, 'w') { |f| f.write(slugs.to_a.sort.uniq.join("\n")) }
end

def run!
    info "STARTING"

    # Load the wishlist, if we can't access it there's no reason to continue.
    hdbits = new_hdbits
    wishlist_items = hdbits.wishlist

    # Load the cache from disk so we don't reprocess watchlist items we have arleady handeled.
    cache = load_watchlist_cache
    warn "Cache is empty, be careful not to DOS anyone!" if cache.empty?

    # Load the watchlist
    watchlist = new_watchlist
    watchlist_items = watchlist.items

    # Check for new, unprocessed entries on the watchlist.
    new_watchlist_items = watchlist_items.select { |i| !cache.member? i.slug }
    if new_watchlist_items.empty?
       info "ABORTING: Watchlist has no new items"
        return
    end

    # Load the ID for each of the items
    load_watchlist_ids(new_watchlist_items)

    # Of the new watchlist entries, check for new entries not on the wishlist.
    ids_to_add = ids_not_on_wishlist(new_watchlist_items, wishlist_items)
    items_to_add = new_watchlist_items.select { |i| ids_to_add.member? i.id }

    # Add the new watchlist entries to the wishlist
    items_to_add.each do |i|
        info "Adding #{i} to wishlist"
        if hdbits.add_to_wishlist(i.id)
          # Put the added slug into the cache so we don't try to add it again next time.
          cache.add(i.slug)
        else
          error "Unable to add #{i} to wishlist"
        end
    end
    save_watchlist_cache(cache)

    info "FINISHED"
end

run!

