#!/usr/bin/ruby

# Install HDBits from https://github.com/brianpartridge/HDBits
require 'hdbits'
require 'imdb_watchlist'
require 'set'

$conf_dir = '~/Dropbox/conf/'

def conf_file(filename)
    File.expand_path($conf_dir + filename)
end

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

def new_hdbits
    user = first_line_from_file(conf_file('hdbits-username'))
    passkey = first_line_from_file(conf_file('hdbits-passkey'))
    HDBits.new(user, passkey)
end

def new_watchlist
    watchlist_url = first_line_from_file(conf_file('imdb-watchlist-url'))
    IMDbWatchlist.new(watchlist_url)
end

def last_watchlist_update_time
    path = conf_file('imdb-watchlist-last-update')
    return Time.at(0) unless File.exists? path
    Time.parse(first_line_from_file(path))
end

def save_last_watchlist_update_time(time)
    path = conf_file('imdb-watchlist-last-update')
    File.open(path, 'w') { |f| f.write(time.to_s) }
end

def recent_watchlist_items(watchlist)
    time = last_watchlist_update_time
    watchlist.items.select { |i| i.date_added > time }.sort_by { |i| i.date_added }
end

def run!
    hdbits = new_hdbits
    wishlist_items = hdbits.wishlist

    watchlist = new_watchlist
    watchlist_items = recent_watchlist_items(watchlist)
    return if watchlist_items.empty?

    ids_to_add = ids_not_on_wishlist(watchlist_items, wishlist_items)
    items_to_add = watchlist_items.select { |i| ids_to_add.member? i.id }
    puts "--- Adding #{ items_to_add.count } ---"
    items_to_add.each do |i| 
        puts i
        puts "ERROR: unable to add #{ i.title } to wishlist" unless hdbits.add_to_wishlist(i.id)
    end
    save_last_watchlist_update_time(watchlist_items.last.date_added)
end

run!

