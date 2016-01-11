#!/usr/bin/ruby

# Install HDBits from https://github.com/brianpartridge/HDBits
require 'hdbits'
require 'imdb_watchlist'
require 'set'

def first_line_from_file(path)
    File.readlines(File.expand_path(path)).first
end

def ids_not_on_wishlist(watchlist_items, wishlist_items)
    watchlist_ids = Set.new(watchlist_items.map { |i| i.id })
    puts "--- Watchlist #{ watchlist_ids.count } ---"
    watchlist_ids.each { |i| puts i }
    
    wishlist_ids = Set.new(wishlist_items.map { |i| 
        # Pad to 7 digits and add the 'tt' prefix.
        "tt#{ i.imdb.to_s.rjust(7, '0') }" 
    })
    puts "--- Wishlist #{ wishlist_ids.count } ---"
    wishlist_ids.each { |i| puts i }
    
    watchlist_ids.subtract(wishlist_ids)
end

def run!
    user = first_line_from_file('~/Dropbox/conf/hdbits-username')
    passkey = first_line_from_file('~/Dropbox/conf/hdbits-passkey')
    hdbits = HDBits.new(user, passkey)
    wishlist_items = hdbits.wishlist

    watchlist_url = first_line_from_file('~/Dropbox/conf/imdb-watchlist')
    watchlist = IMDbWatchlist.new(watchlist_url)

    imdb_ids = ids_not_on_wishlist(watchlist.items, wishlist_items)
    puts "--- Adding #{ imdb_ids.count } ---"
    imdb_ids.each do |id| 
        puts id
        puts "ERROR: unable toadd #{ id } to wishlist" unless hdbits.add_to_wishlist(id)
    end
end

run!

