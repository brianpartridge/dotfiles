#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regenerates the transfers dashboard, prints it to the terminal, or sends
# the daily Pushover digest. See README-transfers.md.

require 'optparse'
require_relative 'lib/transfer_dashboard'

options = { mode: :html, quiet: false, limit: 25 }
OptionParser.new do |opts|
  opts.banner = <<~USAGE
    Usage: transfers-dashboard.rb [options]

    With no options, regenerates the HTML dashboard (default #{TransferDashboard::DEFAULT_OUTPUT},
    override with --out or $TRANSFER_DASHBOARD).
  USAGE
  opts.on('-t', '--text [N]', Integer, 'Print the last N transfers (default 25) instead of writing HTML') do |n|
    options[:mode] = :text
    options[:limit] = n if n
  end
  opts.on('-d', '--digest', 'Send a Pushover summary of the last 24h, then regenerate the HTML') do
    options[:mode] = :digest
  end
  opts.on('-o', '--out PATH', 'Where to write the HTML') { |p| options[:out] = p }
  opts.on('-q', '--quiet', 'Do not print the output path') { options[:quiet] = true }
  opts.on('-h', '--help') do
    puts opts
    exit
  end
end.parse!

report = TransferDashboard::Report.new
case options[:mode]
when :text
  puts TransferDashboard.text(report, limit: options[:limit])
when :digest
  sent = TransferDashboard.digest(report)
  TransferDashboard.generate(report: report, output: options[:out], quiet: options[:quiet])
  puts(sent ? 'Digest sent' : 'Digest NOT sent (see stderr)') unless options[:quiet]
  exit(sent ? 0 : 1)
else
  TransferDashboard.generate(report: report, output: options[:out], quiet: options[:quiet])
end
