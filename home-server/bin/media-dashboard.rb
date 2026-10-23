#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regenerates the media page (every TV episode and movie: in Transmission,
# in the local library, on the NAS) or prints it to the terminal.
# See README-transfers.md, "The media page".

require 'optparse'
require_relative 'lib/media_dashboard'

options = { mode: :html, quiet: false }
OptionParser.new do |opts|
  opts.banner = <<~USAGE
    Usage: media-dashboard.rb [options]

    With no options, regenerates the HTML page (default #{MediaDashboard::DEFAULT_OUTPUT},
    override with --out; follows $TRANSFER_DASHBOARD). transfers-dashboard.rb regenerates
    this page too, so the launch agent needs no change.
  USAGE
  opts.on('-t', '--text', 'Print the inventory instead of writing HTML') { options[:mode] = :text }
  opts.on('-j', '--json', 'Print the inventory as JSON') { options[:mode] = :json }
  opts.on('-o', '--out PATH', 'Where to write the HTML') { |p| options[:out] = p }
  opts.on('-q', '--quiet', 'Do not print the output path') { options[:quiet] = true }
  opts.on('-h', '--help') do
    puts opts
    exit
  end
end.parse!

inventory = MediaInventory::Inventory.new
case options[:mode]
when :text then puts MediaDashboard.text(inventory)
when :json then puts JSON.pretty_generate(inventory.to_h)
else MediaDashboard.generate(inventory: inventory, output: options[:out], quiet: options[:quiet])
end
