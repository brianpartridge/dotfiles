# frozen_string_literal: true

require 'cgi'
require 'erb'
require 'fileutils'
require 'set'
require 'time'
require_relative 'notify'
require_relative 'transfer_log'
require_relative 'transmission_rpc'

# Builds the transfers dashboard: a single static HTML page (intended to live
# in Dropbox so it can be opened from anywhere), a plain-text version for the
# terminal, and a daily Pushover digest.
#
# Besides the transfer log it asks Transmission which torrents are complete,
# so that a torrent that finished without the done-script ever running (the
# quietest failure of all) shows up as "unhandled".
module TransferDashboard
  DEFAULT_OUTPUT = '~/Dropbox/transfers/index.html'
  RECENT_LIMIT = 200
  DAY = 24 * 60 * 60
  WEEK = 7 * DAY

  STATUS_LABELS = {
    'ok' => 'OK',
    'warning' => 'Needs attention',
    'error' => 'Failed'
  }.freeze

  OUTCOME_LABELS = {
    'tv' => 'TV episode',
    'movie' => 'Movie',
    'no_media' => 'No media found',
    'multiple_media' => 'Multiple media files',
    'unknown_media' => 'Unrecognised name',
    'error' => 'Error',
    'no_torrent' => 'No torrent info'
  }.freeze

  # Everything the dashboard shows, gathered once.
  class Report
    attr_reader :records, :torrents, :rpc_error, :generated_at

    def initialize(log: TransferLog.new, rpc: TransmissionRPC.from_config, limit: RECENT_LIMIT, now: Time.now)
      @generated_at = now
      @records = log.records(limit: limit)
      @torrents = []
      @rpc_error = nil
      begin
        @torrents = rpc.torrents
      rescue TransmissionRPC::Error => e
        @rpc_error = e.message
      end
    end

    def records_since(seconds)
      cutoff = @generated_at - seconds
      @records.select do |r|
        t = TransferLog.time_of(r)
        t && t >= cutoff
      end
    end

    def counts(seconds)
      counts = { 'ok' => 0, 'warning' => 0, 'error' => 0 }
      records_since(seconds).each { |r| counts[r['status']] = counts.fetch(r['status'], 0) + 1 }
      counts
    end

    # Torrents Transmission reports as complete that have no transfer record,
    # meaning the done-script never ran (or never got as far as recording).
    def unhandled
      hashes = Set.new
      names = Set.new
      @records.each do |r|
        torrent = r['torrent'] || {}
        hashes << torrent['hash'].to_s.downcase unless torrent['hash'].to_s.empty?
        names << torrent['name'] unless torrent['name'].to_s.empty?
      end
      completed.reject { |t| hashes.include?(t['hashString'].to_s.downcase) || names.include?(t['name']) }
    end

    def completed
      @torrents.select { |t| t['percentDone'].to_f >= 1.0 }.sort_by { |t| -t['doneDate'].to_i }
    end

    def active
      @torrents.reject { |t| t['percentDone'].to_f >= 1.0 }.sort_by { |t| -t['percentDone'].to_f }
    end

    def transmission_errors
      @torrents.select { |t| t['error'].to_i != 0 }
    end
  end

  module_function

  def generate(output: nil, quiet: false, report: nil)
    report ||= Report.new
    path = File.expand_path(output || ENV['TRANSFER_DASHBOARD'] || DEFAULT_OUTPUT)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, Html.new(report).render)
    File.rename(tmp, path) # so Dropbox never syncs a half-written page
    puts "Wrote #{path}" unless quiet
    path
  end

  def text(report = nil, limit: 25)
    report ||= Report.new
    Text.new(report, limit: limit).render
  end

  # Sends a Pushover summary of the last `window` seconds. Sent even when
  # nothing happened, so a quiet day and a dead pipeline look different.
  def digest(report = nil, window: DAY)
    report ||= Report.new
    counts = report.counts(window)
    unhandled = report.unhandled
    hours = (window / 3600).round

    title = "Transfers, last #{hours}h: #{counts['ok']} ok, #{counts['warning']} attention, #{counts['error']} failed"
    lines = report.records_since(window).first(10).map do |r|
      "#{status_glyph(r['status'])} #{torrent_name(r)}"
    end
    lines << "(no transfers in the last #{hours}h)" if lines.empty?
    unless unhandled.empty?
      lines << ''
      lines << "#{unhandled.count} complete in Transmission with no record:"
      unhandled.first(5).each { |t| lines << "• #{t['name']}" }
    end
    lines << '' << "Transmission unreachable: #{report.rpc_error}" if report.rpc_error

    trouble = counts['error'].positive? || !unhandled.empty? || report.rpc_error
    Notify.push(lines.join("\n"), title: title, priority: trouble ? :high : :low)
  end

  def status_glyph(status)
    { 'ok' => '✓', 'warning' => '!', 'error' => '✕' }.fetch(status, '?')
  end

  def torrent_name(record)
    (record['torrent'] || {})['name'] || '(unknown torrent)'
  end

  def relative_time(time, now)
    return 'unknown' unless time

    seconds = (now - time).to_i
    return 'just now' if seconds < 60
    return "#{seconds / 60}m ago" if seconds < 3600
    return "#{seconds / 3600}h ago" if seconds < DAY

    "#{seconds / DAY}d ago"
  end

  # Terminal rendering.
  class Text
    def initialize(report, limit: 25)
      @report = report
      @limit = limit
    end

    def render
      out = []
      now = @report.generated_at
      week = @report.counts(WEEK)
      out << "Transfers (last 7 days): #{week['ok']} ok, #{week['warning']} attention, #{week['error']} failed"
      out << "Transmission: #{@report.rpc_error ? "unreachable (#{@report.rpc_error})" : "#{@report.completed.count} complete, #{@report.active.count} active"}"

      unhandled = @report.unhandled
      unless unhandled.empty?
        out << '' << "UNHANDLED (complete in Transmission, no record):"
        unhandled.each { |t| out << "  #{t['name']}" }
      end

      out << '' << format('%-2s %-12s %-22s %s', '', 'when', 'outcome', 'torrent')
      @report.records.first(@limit).each do |r|
        time = TransferLog.time_of(r)
        out << format('%-2s %-12s %-22s %s',
                      TransferDashboard.status_glyph(r['status']),
                      TransferDashboard.relative_time(time, now),
                      OUTCOME_LABELS.fetch(r['outcome'], r['outcome'].to_s),
                      TransferDashboard.torrent_name(r))
        out << "               #{r['message']}" unless r['status'] == 'ok'
      end
      out << '  (no transfers recorded yet)' if @report.records.empty?
      out.join("\n") + "\n"
    end
  end

  # Static HTML rendering. No JavaScript, no external assets, so it reads the
  # same from Dropbox on a phone as it does in a desktop browser.
  class Html
    def initialize(report)
      @report = report
    end

    def render
      TEMPLATE.result(binding)
    end

    private

    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def status_label(status)
      STATUS_LABELS.fetch(status, status.to_s)
    end

    def outcome_label(outcome)
      OUTCOME_LABELS.fetch(outcome, outcome.to_s)
    end

    def when_html(record)
      time = TransferLog.time_of(record)
      absolute = time ? time.strftime('%Y-%m-%d %H:%M') : ''
      %(<time title="#{h(absolute)}">#{h(TransferDashboard.relative_time(time, @report.generated_at))}</time>)
    end

    def epoch_html(epoch)
      return '' if epoch.to_i.zero?

      when_html('ts' => Time.at(epoch.to_i).iso8601)
    end

    def action_label(record)
      case record['action']
      when 'copy' then 'copied to'
      when 'extract_copy' then 'extracted and copied to'
      when 'link' then 'linked into'
      when 'extract_link' then 'extracted and linked into'
      end
    end

    def size_label(bytes)
      bytes = bytes.to_f
      return format('%.1f GB', bytes / 1e9) if bytes >= 1e9
      return format('%.0f MB', bytes / 1e6) if bytes >= 1e6

      format('%.0f KB', bytes / 1e3)
    end

    # ERB.new grew keyword arguments in Ruby 2.6; the macOS system Ruby (2.3)
    # only understands the positional form.
    def self.erb(template)
      if ERB.instance_method(:initialize).parameters.include?([:key, :trim_mode])
        ERB.new(template, trim_mode: '-')
      else
        ERB.new(template, nil, '-')
      end
    end

    TEMPLATE = erb(<<~'HTML')
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <title>Transfers</title>
      <style>
        :root {
          color-scheme: light dark;
          --surface: #fcfcfb;
          --surface-2: #f1f1ee;
          --border: #dededa;
          --text: #0b0b0b;
          --text-2: #52514e;
          --text-3: #7a7974;
          --good: #0ca30c;
          --warning: #b57a00;
          --critical: #d03b3b;
          --accent: #2a78d6;
          --meter-track: #d6e4f5;
        }
        @media (prefers-color-scheme: dark) {
          :root:not([data-theme="light"]) {
            --surface: #1a1a19;
            --surface-2: #242423;
            --border: #3a3a38;
            --text: #ffffff;
            --text-2: #c3c2b7;
            --text-3: #8d8c85;
            --good: #0ca30c;
            --warning: #fab219;
            --critical: #d03b3b;
            --accent: #3987e5;
            --meter-track: #2b3a4d;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 16px;
          background: var(--surface); color: var(--text);
          font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        }
        main { max-width: 860px; margin: 0 auto; }
        h1 { font-size: 22px; margin: 0 0 2px; }
        h2 { font-size: 15px; margin: 28px 0 10px; color: var(--text-2); text-transform: uppercase; letter-spacing: .04em; }
        .sub { color: var(--text-3); font-size: 13px; margin: 0 0 18px; }
        .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; }
        .tile { background: var(--surface-2); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; }
        .tile .label { font-size: 12px; color: var(--text-2); }
        .tile .value { font-size: 30px; font-weight: 600; line-height: 1.15; margin-top: 4px; }
        .tile.attn .value::before, .tile.fail .value::before, .tile.ok .value::before {
          display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin: 0 8px 4px 0; content: "";
        }
        .tile.ok .value::before { background: var(--good); }
        .tile.attn .value::before { background: var(--warning); }
        .tile.fail .value::before { background: var(--critical); }
        .notice { border-left: 3px solid var(--warning); background: var(--surface-2); padding: 10px 12px; border-radius: 0 8px 8px 0; margin: 16px 0; font-size: 14px; }
        .notice.critical { border-color: var(--critical); }
        ul.list { list-style: none; margin: 0; padding: 0; border: 1px solid var(--border); border-radius: 10px; overflow: hidden; }
        ul.list li { padding: 10px 12px; border-top: 1px solid var(--border); display: grid; grid-template-columns: 26px minmax(0, 1fr); gap: 10px; }
        ul.list li:first-child { border-top: 0; }
        .badge { width: 22px; height: 22px; border-radius: 50%; color: #fff; font-weight: 700; font-size: 13px; display: inline-flex; align-items: center; justify-content: center; margin-top: 1px; }
        .badge.ok { background: var(--good); }
        .badge.warning { background: var(--warning); }
        .badge.error { background: var(--critical); }
        .body > * + * { margin-top: 2px; }
        .name { font-weight: 600; word-break: break-word; }
        .meta { color: var(--text-2); font-size: 13px; }
        .meta b { font-weight: 600; color: var(--text); }
        .msg { font-size: 13px; color: var(--text-2); word-break: break-word; }
        li.warning .msg, li.error .msg { color: var(--text); }
        details { font-size: 12px; margin-top: 4px; }
        summary { cursor: pointer; color: var(--accent); }
        pre { background: var(--surface-2); padding: 8px 10px; border-radius: 6px; overflow-x: auto; margin: 6px 0 0; font-size: 11.5px; white-space: pre-wrap; word-break: break-all; }
        code { font-size: 12px; }
        .meter { position: relative; height: 6px; border-radius: 3px; background: var(--meter-track); margin-top: 6px; overflow: hidden; }
        .meter span { display: block; height: 100%; background: var(--accent); border-radius: 3px; }
        .empty { color: var(--text-3); font-size: 14px; padding: 12px; border: 1px dashed var(--border); border-radius: 10px; }
        time { font-variant-numeric: tabular-nums; }
        footer { color: var(--text-3); font-size: 12px; margin: 28px 0 8px; }
      </style>
      </head>
      <body>
      <main>
        <h1>Transfers</h1>
        <p class="sub">Generated <%= h(@report.generated_at.strftime('%a %b %e, %H:%M')) %></p>

        <%- week = @report.counts(WEEK); unhandled = @report.unhandled -%>
        <section class="tiles" aria-label="Last 7 days">
          <div class="tile ok"><div class="label">Filed OK, 7 days</div><div class="value"><%= week['ok'] %></div></div>
          <div class="tile attn"><div class="label">Needs attention, 7 days</div><div class="value"><%= week['warning'] %></div></div>
          <div class="tile fail"><div class="label">Failed, 7 days</div><div class="value"><%= week['error'] %></div></div>
          <div class="tile <%= unhandled.empty? ? '' : 'fail' %>"><div class="label">Complete but unhandled</div><div class="value"><%= @report.rpc_error ? '?' : unhandled.count %></div></div>
        </section>

        <%- if @report.rpc_error -%>
        <div class="notice">
          <b>Transmission unreachable.</b> Cannot check for torrents that finished without being handled.
          Enable remote access in Transmission (Preferences &gt; Remote) or check <code>~/Dropbox/conf/transmission.json</code>.
          <div class="msg"><%= h(@report.rpc_error) %></div>
        </div>
        <%- end -%>

        <%- unless unhandled.empty? -%>
        <h2>Complete in Transmission, never handled</h2>
        <div class="notice critical">These finished downloading but no transfer record exists, so the done-script did not run or crashed before recording. Re-run it with the <code>repro</code> command from a similar record, or check <code>~/logs/torrent-finished.out</code>.</div>
        <ul class="list">
          <%- unhandled.each do |t| -%>
          <li class="error">
            <span class="badge error" aria-label="Unhandled">!</span>
            <div class="body">
              <div class="name"><%= h(t['name']) %></div>
              <div class="meta">finished <%= epoch_html(t['doneDate']) %> · <%= h(TransmissionRPC.status_name(t['status'])) %> · <%= h(size_label(t['totalSize'])) %> · <%= h(t['downloadDir']) %></div>
              <%- unless t['errorString'].to_s.empty? -%><div class="msg">Transmission error: <%= h(t['errorString']) %></div><%- end -%>
            </div>
          </li>
          <%- end -%>
        </ul>
        <%- end -%>

        <%- active = @report.active -%>
        <%- unless active.empty? -%>
        <h2>In progress</h2>
        <ul class="list">
          <%- active.each do |t| -%>
          <li>
            <span class="badge" style="background: var(--accent)" aria-label="In progress">↓</span>
            <div class="body">
              <div class="name"><%= h(t['name']) %></div>
              <div class="meta"><b><%= (t['percentDone'].to_f * 100).round %>%</b> · <%= h(TransmissionRPC.status_name(t['status'])) %> · <%= h(size_label(t['totalSize'])) %> · added <%= epoch_html(t['addedDate']) %><%- unless t['errorString'].to_s.empty? -%> · <%= h(t['errorString']) %><%- end -%></div>
              <div class="meter" role="progressbar" aria-valuenow="<%= (t['percentDone'].to_f * 100).round %>" aria-valuemin="0" aria-valuemax="100"><span style="width: <%= (t['percentDone'].to_f * 100).round %>%"></span></div>
            </div>
          </li>
          <%- end -%>
        </ul>
        <%- end -%>

        <h2>Recent transfers</h2>
        <%- if @report.records.empty? -%>
        <div class="empty">No transfers recorded yet. Records appear here after Transmission runs <code>torrent-finished.sh</code>.</div>
        <%- else -%>
        <ul class="list">
          <%- @report.records.each do |r| -%>
          <%- status = r['status'].to_s -%>
          <li class="<%= h(status) %>">
            <span class="badge <%= h(status) %>" aria-label="<%= h(status_label(status)) %>"><%= TransferDashboard.status_glyph(status) %></span>
            <div class="body">
            <div class="name"><%= h(TransferDashboard.torrent_name(r)) %></div>
            <div class="meta"><%= when_html(r) %> · <b><%= h(status_label(status)) %></b> · <%= h(outcome_label(r['outcome'])) %><%- if action_label(r) -%> · <%= h(action_label(r)) %> <%= h(File.dirname(r['destination'].to_s)) %><%- end -%></div>
            <div class="msg"><%= h(r['message']) %></div>
            <%- if r['error'] || r['media_file'] || r['repro'] -%>
            <details>
              <summary>Details</summary>
              <%- if r['media_file'] -%><div>Media file: <code><%= h(r['media_file']) %></code></div><%- end -%>
              <%- if r['destination'] -%><div>Destination: <code><%= h(r['destination']) %></code></div><%- end -%>
              <%- if r['duration_s'] -%><div>Took <%= h(r['duration_s']) %>s<%- if r.key?('notified') -%>, notification <%= r['notified'] ? 'sent' : 'not sent' %><%- end -%></div><%- end -%>
              <%- if r['error'] -%><pre><%= h(r['error']['class']) %>: <%= h(r['error']['message']) %>
      <%= h(Array(r['error']['backtrace']).join("\n")) %></pre><%- end -%>
              <%- if r['repro'] -%><div>Re-run:</div><pre><%= h(r['repro']) %></pre><%- end -%>
            </details>
            <%- end -%>
            </div>
          </li>
          <%- end -%>
        </ul>
        <%- end -%>

        <footer>
          Transmission: <%= @report.rpc_error ? 'unreachable' : "#{@report.completed.count} complete, #{active.count} active" %> ·
          showing the last <%= @report.records.count %> records
        </footer>
      </main>
      </body>
      </html>
    HTML
  end
end
