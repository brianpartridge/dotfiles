#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regenerates the transfers dashboard or prints it to the terminal.
# See README-transfers.md.

require 'optparse'
require_relative 'lib/media_dashboard'
require_relative 'lib/transfer_dashboard'

options = { mode: :html, quiet: false, limit: 25 }
OptionParser.new do |opts|
  opts.banner = <<~USAGE
    Usage: transfers-dashboard.rb [options]

    With no options, regenerates the HTML dashboard (default #{TransferDashboard::DEFAULT_OUTPUT},
    override with --out or $TRANSFER_DASHBOARD). Notifications link to #{TransferDashboard.url}
    (override with $TRANSFER_DASHBOARD_URL).
  USAGE
  opts.on('-t', '--text [N]', Integer, 'Print the last N transfers (default 25) instead of writing HTML') do |n|
    options[:mode] = :text
    options[:limit] = n if n
  end
  opts.on('-o', '--out PATH', 'Where to write the HTML') { |p| options[:out] = p }
  opts.on('-q', '--quiet', 'Do not print the output path') { options[:quiet] = true }
  opts.on('--no-media', 'Skip the media page (media-dashboard.rb)') { options[:media] = false }
  opts.on('-h', '--help') do
    puts opts
    exit
  end
end.parse!

report = TransferDashboard::Report.new
case options[:mode]
when :text
  puts TransferDashboard.text(report, limit: options[:limit])
else
  TransferDashboard.generate(report: report, output: options[:out], quiet: options[:quiet])
  # The media page lives next to it and is refreshed on the same schedule.
  # It must never take the transfers page down with it.
  begin
    MediaDashboard.generate(output: options[:out] && MediaDashboard.output_path(File.join(File.dirname(options[:out]), 'media', 'index.html')),
                            quiet: options[:quiet])
  rescue StandardError => e
    warn "media page not written: #{e.class}: #{e.message}"
  end unless options[:media] == false
end
