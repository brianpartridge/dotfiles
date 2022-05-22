#!/usr/bin/ruby
# frozen_string_literal: true

require 'openssl'
require 'rss'
require_relative 'lib/tweet'

$conf_dir = '~/Dropbox/conf/'
$dl_dir = '~/Dropbox/torrents/'

def conf_file(filename)
  File.expand_path($conf_dir + filename)
end

def first_line_from_file(path)
  File.readlines(File.expand_path(path)).first
end

def dl_item_path(item)
  File.expand_path($dl_dir + item.title + '.torrent')
end

def rss_url(internal_only)
  params = { 'passkey' => first_line_from_file(conf_file('hdbits-passkey')) }
  params['type_origin'] = 1 if internal_only
  'https://hdbits.org/rss/wishlist?' + URI.encode_www_form(params)
end

def load_available_wishlist_items(internal_only = true)
  RSS::Parser.parse(open(rss_url(internal_only),  {ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE}).read).items
end

# Only download items that are 720p, and remove duplicates to only download unique items.
def filter_items(items)
  items.select { |i| i.title[/720p/] }.uniq(&:description)
end

def download_item(item)
  puts "Downloading #{item.title}"
  tweet "START:Download - #{item.title}"
  open(dl_item_path(item), 'wb') do |f|
    f << open(item.link,  {ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE}).read
  end
end

def run!
  all_items = load_available_wishlist_items
  puts "#{all_items.count} available on wishlist"

  items = filter_items(all_items)
  puts "#{items.count} queued for download"

  items.each { |i| download_item(i) }
  puts 'Done'
end

run!
