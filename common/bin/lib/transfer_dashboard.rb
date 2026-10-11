# frozen_string_literal: true

require 'cgi'
require 'erb'
require 'fileutils'
require 'json'
require 'set'
require 'socket'
require 'time'
require_relative 'notify'
require_relative 'transfer_log'
require_relative 'transmission_rpc'

# Builds the transfers dashboard: a single static HTML page served by the
# Mac's built-in Apache (see README-transfers.md) and a plain-text version
# for the terminal.
#
# Besides the transfer log it asks Transmission which torrents are complete,
# so that a torrent that finished without the done-script ever running (the
# quietest failure of all) shows up as "unhandled".
module TransferDashboard
  # Apache's document root on macOS; enable it with `sudo apachectl start`.
  DEFAULT_OUTPUT = '/Library/WebServer/Documents/transfers/index.html'
  DEFAULT_URL_PATH = '/transfers/'
  RECENT_LIMIT = 200
  DAY = 24 * 60 * 60
  WEEK = 7 * DAY
  UNHANDLED_WINDOW = WEEK # how far back to look for complete-but-unhandled torrents

  STATUS_LABELS = {
    'ok' => 'Filed',
    'other' => 'Other',
    'error' => 'Failed'
  }.freeze

  # Records written before "other" existed used "warning" for the same thing.
  LEGACY_STATUSES = { 'warning' => 'other' }.freeze

  OUTCOME_LABELS = {
    'tv' => 'TV episode',
    'movie' => 'Movie',
    'ebook' => 'eBook',
    'comic' => 'Comic',
    'audiobook' => 'Audiobook',
    'music' => 'Music',
    'no_media' => 'No media files',
    'multiple_media' => 'Could not pick a file',
    'unknown_media' => 'Not TV or a movie',
    'error' => 'Error',
    'no_torrent' => 'No torrent info'
  }.freeze

  # Everything the dashboard shows, gathered once.
  class Report
    attr_reader :records, :torrents, :rpc_error, :generated_at

    def initialize(log: TransferLog.new, rpc: TransmissionRPC.from_config, limit: RECENT_LIMIT, now: Time.now)
      @generated_at = now
      @records = log.records(limit: limit).map do |r|
        r.merge('status' => LEGACY_STATUSES.fetch(r['status'], r['status']))
      end
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
      counts = { 'ok' => 0, 'other' => 0, 'error' => 0 }
      records_since(seconds).each { |r| counts[r['status']] = counts.fetch(r['status'], 0) + 1 }
      counts
    end

    # Torrents Transmission reports as complete that have no transfer record,
    # meaning the done-script never ran (or never got as far as recording).
    # Limited to torrents that finished within `window` seconds, so that
    # everything downloaded before this pipeline existed is not flagged forever.
    def unhandled(window: UNHANDLED_WINDOW)
      hashes = Set.new
      names = Set.new
      @records.each do |r|
        torrent = r['torrent'] || {}
        hashes << torrent['hash'].to_s.downcase unless torrent['hash'].to_s.empty?
        names << torrent['name'] unless torrent['name'].to_s.empty?
      end
      cutoff = @generated_at - window
      completed
        .select { |t| Report.finished_at(t) >= cutoff }
        .reject { |t| hashes.include?(t['hashString'].to_s.downcase) || names.include?(t['name']) }
    end

    # When Transmission finished the torrent. A torrent added already complete
    # has no doneDate, so fall back to when it was added.
    def self.finished_at(torrent)
      epoch = torrent['doneDate'].to_i
      epoch = torrent['addedDate'].to_i if epoch.zero?
      Time.at(epoch)
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

  # Where the page can be opened from another device; notifications link to
  # it. Override with $TRANSFER_DASHBOARD_URL when it is served from elsewhere.
  def url
    return ENV['TRANSFER_DASHBOARD_URL'] unless ENV['TRANSFER_DASHBOARD_URL'].to_s.empty?

    host = Socket.gethostname.to_s
    host = "#{host}.local" unless host.empty? || host.include?('.')
    "http://#{host}#{DEFAULT_URL_PATH}"
  end

  def generate(output: nil, quiet: false, report: nil)
    report ||= Report.new
    path = File.expand_path(output || ENV['TRANSFER_DASHBOARD'] || DEFAULT_OUTPUT)
    FileUtils.mkdir_p(File.dirname(path))
    write_atomically(path, Html.new(report).render)
    json_path = File.join(File.dirname(path), 'transfers.json')
    write_atomically(json_path, JSON.pretty_generate(summary(report)))
    puts "Wrote #{path} and #{File.basename(json_path)}" unless quiet
    path
  end

  # The latest record per torrent, keyed by hash and by name, for the
  # Transmission web UI's per-row indicator (common/web/transmission/javascript/extras/transfers.js).
  def summary(report)
    by_hash = {}
    by_name = {}
    report.records.each do |r|
      torrent = r['torrent'] || {}
      entry = {
        'ts' => r['ts'], 'status' => r['status'], 'outcome' => r['outcome'],
        'message' => r['message'], 'destination' => r['destination'],
        'file_command' => r['file_command']
      }
      hash = torrent['hash'].to_s.downcase
      name = torrent['name'].to_s
      by_hash[hash] ||= entry unless hash.empty? # records are newest first
      by_name[name] ||= entry unless name.empty?
    end
    {
      'generated_at' => report.generated_at.iso8601,
      'unhandled_window_days' => UNHANDLED_WINDOW / DAY,
      'dashboard_url' => url,
      'by_hash' => by_hash,
      'by_name' => by_name
    }
  end

  def write_atomically(path, content)
    tmp = "#{path}.tmp"
    File.write(tmp, content)
    File.rename(tmp, path) # so a reader never gets a half-written file
  end

  def text(report = nil, limit: 25)
    report ||= Report.new
    Text.new(report, limit: limit).render
  end

  def status_glyph(status)
    { 'ok' => '✓', 'other' => '–', 'error' => '✕' }.fetch(status, '?')
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
      out << "Transfers (last 7 days): #{week['ok']} filed, #{week['other']} other, #{week['error']} failed"
      out << "Transmission: #{@report.rpc_error ? "unreachable (#{@report.rpc_error})" : "#{@report.completed.count} complete, #{@report.active.count} active"}"

      unhandled = @report.unhandled
      unless unhandled.empty?
        out << '' << "UNHANDLED (complete in Transmission in the last #{UNHANDLED_WINDOW / DAY} days, no record):"
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
        out << "               file: #{r['file_command']}" if r['file_command']
      end
      out << '  (no transfers recorded yet)' if @report.records.empty?
      out.join("\n") + "\n"
    end
  end

  # Static HTML rendering. No external assets and only a few lines of inline
  # script (the copy buttons), so it reads the same on a phone as on a desktop.
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
      when 'symlink' then 'symlinked into'
      when 'extract_link' then 'extracted and linked into'
      when 'extract_symlink' then 'extracted and symlinked into'
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
        .tile.other .value::before, .tile.fail .value::before, .tile.ok .value::before {
          display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin: 0 8px 4px 0; content: "";
        }
        .tile.ok .value::before { background: var(--good); }
        .tile.other .value::before { background: var(--text-3); }
        .tile.fail .value::before { background: var(--critical); }
        .notice { border-left: 3px solid var(--warning); background: var(--surface-2); padding: 10px 12px; border-radius: 0 8px 8px 0; margin: 16px 0; font-size: 14px; }
        .notice.critical { border-color: var(--critical); }
        ul.list { list-style: none; margin: 0; padding: 0; border: 1px solid var(--border); border-radius: 10px; overflow: hidden; }
        ul.list li { padding: 10px 12px; border-top: 1px solid var(--border); display: grid; grid-template-columns: 26px minmax(0, 1fr); gap: 10px; }
        ul.list li:first-child { border-top: 0; }
        .badge { width: 22px; height: 22px; border-radius: 50%; color: #fff; font-weight: 700; font-size: 13px; display: inline-flex; align-items: center; justify-content: center; margin-top: 1px; }
        .badge.ok { background: var(--good); }
        .badge.other { background: var(--text-3); }
        .badge.error { background: var(--critical); }
        .body > * + * { margin-top: 2px; }
        .name { font-weight: 600; word-break: break-word; }
        .meta { color: var(--text-2); font-size: 13px; }
        .meta b { font-weight: 600; color: var(--text); }
        .msg { font-size: 13px; color: var(--text-2); word-break: break-word; }
        li.error .msg { color: var(--text); }
        details { font-size: 12px; margin-top: 4px; }
        summary { cursor: pointer; color: var(--accent); }
        pre { background: var(--surface-2); padding: 8px 10px; border-radius: 6px; overflow-x: auto; margin: 6px 0 0; font-size: 11.5px; white-space: pre-wrap; word-break: break-all; }
        .cmd { position: relative; }
        .cmd pre { padding-right: 64px; }
        .cmd button { position: absolute; top: 10px; right: 6px; font: inherit; font-size: 11px; padding: 2px 8px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface); color: var(--accent); cursor: pointer; }
        .cmd button:hover { border-color: var(--accent); }
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
          <div class="tile other"><div class="label">Other, 7 days</div><div class="value"><%= week['other'] %></div></div>
          <div class="tile fail"><div class="label">Failed, 7 days</div><div class="value"><%= week['error'] %></div></div>
          <div class="tile <%= unhandled.empty? ? '' : 'fail' %>"><div class="label">Complete but unhandled, <%= UNHANDLED_WINDOW / DAY %> days</div><div class="value"><%= @report.rpc_error ? '?' : unhandled.count %></div></div>
        </section>

        <%- if @report.rpc_error -%>
        <div class="notice">
          <b>Transmission unreachable.</b> Cannot check for torrents that finished without being handled.
          Enable remote access in Transmission (Preferences &gt; Remote) or check <code>~/Dropbox/conf/transmission.json</code>.
          <div class="msg"><%= h(@report.rpc_error) %></div>
        </div>
        <%- end -%>

        <%- unless unhandled.empty? -%>
        <h2>Complete in Transmission in the last <%= UNHANDLED_WINDOW / DAY %> days, never handled</h2>
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
            <%- if r['error'] || r['media_file'] || r['repro'] || r['file_command'] -%>
            <details>
              <summary>Details</summary>
              <%- if r['media_file'] -%><div>Media file: <code><%= h(r['media_file']) %></code></div><%- end -%>
              <%- if r['destination'] -%><div>Destination: <code><%= h(r['destination']) %></code></div><%- end -%>
              <%- if r['duration_s'] -%><div>Took <%= h(r['duration_s']) %>s<%- if r.key?('notified') -%>, notification <%= r['notified'] ? 'sent' : 'not sent' %><%- end -%></div><%- end -%>
              <%- if r['error'] -%><pre><%= h(r['error']['class']) %>: <%= h(r['error']['message']) %>
      <%= h(Array(r['error']['backtrace']).join("\n")) %></pre><%- end -%>
              <%- if r['file_command'] -%><div>Not filed. To copy it into place, run this on the Mac:</div><div class="cmd"><pre><%= h(r['file_command']) %></pre><button type="button" class="copy">Copy</button></div><%- end -%>
              <%- if r['repro'] -%><div>Re-run:</div><div class="cmd"><pre><%= h(r['repro']) %></pre><button type="button" class="copy">Copy</button></div><%- end -%>
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
      <script>
      // Copy buttons. The page is served over plain HTTP, where navigator.clipboard
      // is unavailable, so select-and-copy comes first and the clipboard API is the fallback.
      document.addEventListener('click', function (event) {
        var button = event.target.closest ? event.target.closest('button.copy') : null;
        if (!button) { return; }
        var pre = button.parentNode.querySelector('pre');
        var text = pre.textContent;
        var done = function (ok) {
          button.textContent = ok ? 'Copied' : 'Select and copy';
          if (!ok) { var range = document.createRange(); range.selectNodeContents(pre); var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range); }
          setTimeout(function () { button.textContent = 'Copy'; }, 1500);
        };
        var ok = false;
        try {
          var area = document.createElement('textarea');
          area.value = text;
          area.setAttribute('readonly', '');
          area.style.position = 'fixed';
          area.style.top = '-1000px';
          document.body.appendChild(area);
          area.select();
          area.setSelectionRange(0, text.length);
          ok = document.execCommand('copy');
          document.body.removeChild(area);
        } catch (e) { ok = false; }
        if (ok || !navigator.clipboard) { done(ok); return; }
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
      });
      </script>
      </body>
      </html>
    HTML
  end
end
