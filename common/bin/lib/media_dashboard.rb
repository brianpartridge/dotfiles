# frozen_string_literal: true

require 'cgi'
require 'erb'
require 'fileutils'
require 'json'
require 'time'
require_relative 'media_inventory'
require_relative 'transfer_dashboard'

# The media page: every TV episode and movie, where it is and what it
# costs, from MediaInventory. Static HTML next to the transfers dashboard
# (/transfers/media/), plus media.json and a terminal view.
module MediaDashboard
  DEFAULT_OUTPUT = File.join(File.dirname(TransferDashboard::DEFAULT_OUTPUT), 'media', 'index.html')

  STATE_GLYPHS = {
    'downloading' => '↓', 'seeding' => '↑', 'stopped' => '∥', 'unfiled' => '!', 'promoted' => '⇪',
    'library_only' => '▤', 'mixed' => '±'
  }.freeze
  STATE_CLASSES = {
    'downloading' => 'active', 'seeding' => 'ok', 'stopped' => 'other', 'unfiled' => 'error', 'promoted' => 'nas',
    'library_only' => 'other', 'mixed' => 'other'
  }.freeze

  SHOW_FREES_FROM = 1_000_000 # below this, "removing frees" is just .nfo files and samples

  module_function

  # Next to the transfers page unless told otherwise.
  def output_path(output = nil)
    return File.expand_path(output) if output
    return File.join(File.dirname(File.expand_path(ENV['TRANSFER_DASHBOARD'])), 'media', 'index.html') if ENV['TRANSFER_DASHBOARD']

    DEFAULT_OUTPUT
  end

  def generate(output: nil, quiet: false, inventory: nil)
    inventory ||= MediaInventory::Inventory.new
    path = output_path(output)
    FileUtils.mkdir_p(File.dirname(path))
    TransferDashboard.write_atomically(path, Html.new(inventory).render)
    json_path = File.join(File.dirname(path), 'media.json')
    TransferDashboard.write_atomically(json_path, JSON.pretty_generate(inventory.to_h))
    puts "Wrote #{path} and #{File.basename(json_path)}" unless quiet
    path
  end

  def text(inventory = nil)
    inventory ||= MediaInventory::Inventory.new
    Text.new(inventory).render
  end

  def state_label(state)
    return 'Mixed' if state == 'mixed'

    MediaInventory::STATE_LABELS.fetch(state, state.to_s)
  end

  def kind_label(kind)
    MediaInventory::KIND_LABELS.fetch(kind, kind.to_s)
  end

  # Terminal rendering: one line per torrent or library file, its files beneath.
  class Text
    def initialize(inventory)
      @inv = inventory
    end

    def render
      size = TransferDashboard.method(:size_label)
      t = @inv.totals
      out = []
      out << "Library: #{size.call(t['library_bytes'])} in #{t['library_files']} files"
      out << "Transmission: #{@inv.rpc_error ? "unreachable (#{@inv.rpc_error})" : "#{size.call(t['torrent_bytes'])} in #{t['torrents']} torrents, #{t['seeding']} seeding"}"
      out << "Stored once (library hardlinks into the downloads): #{size.call(t['shared_bytes'])}"
      out << "Reclaimable by removing #{t['reclaimable_torrents']} finished torrents: #{size.call(t['reclaimable_bytes'])}"
      out << "Needs attention: #{t['warnings']}" if t['warnings'].positive?
      out << '' << format('%-2s %-9s %-34s %-9s %s', '', 'size', 'state', 'kind', 'name')
      @inv.groups.each do |g|
        out << format('%-2s %-9s %-34s %-9s %s', MediaDashboard::STATE_GLYPHS.fetch(g.state, '?'), size.call(g.size),
                      MediaDashboard.state_label(g.state), MediaDashboard.kind_label(g.kind), g.name)
        torrent = g.torrent
        if torrent
          line = "             #{torrent['status']}, ratio #{torrent['ratio']}"
          line += ", removing frees #{size.call(g.frees_if_removed)}" if g.frees_if_removed >= MediaDashboard::SHOW_FREES_FROM
          out << line
        end
        g.items.each do |i|
          next if g.items.count == 1 && i.warnings.empty? && !torrent.nil? && i.name == File.basename(torrent['name'])

          where = i.in_library? ? (i.link ? "library (#{i.link})" : 'library') : 'not in library'
          where += ', on NAS' if i.on_nas?
          out << "             #{size.call(i.size).rjust(9)}  #{i.name}  [#{where}]"
          i.warnings.each { |w| out << "               ! #{w}" }
        end
      end
      out << '  (nothing found)' if @inv.groups.empty?
      out.join("\n") + "\n"
    end
  end

  # Static HTML. The filters and sorting are a little inline script over
  # data attributes, so the page still lists everything without it.
  class Html
    def initialize(inventory)
      @inv = inventory
      @totals = inventory.totals
    end

    def render
      TEMPLATE.result(binding)
    end

    private

    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def size_label(bytes)
      TransferDashboard.size_label(bytes)
    end

    def when_html(time)
      return '' unless time

      %(<time title="#{h(time.strftime('%Y-%m-%d %H:%M'))}">#{h(TransferDashboard.relative_time(time, @inv.generated_at))}</time>)
    end

    def library_label(item)
      return 'not in library' unless item.in_library?

      dir = File.dirname(item.library_path).sub(/\A#{Regexp.escape(@inv.media_root)}\/?/, '~/Media/')
      item.link ? "#{dir} (#{MediaInventory::LINK_LABELS.fetch(item.link, item.link)})" : dir
    end

    def nas_label(item)
      return nil unless item.on_nas?

      verified = item.nas['verified']
      note = verified == true ? 'confirmed' : verified == false ? 'MISSING on the NAS' : 'not mounted, unconfirmed'
      "on NAS (#{note})"
    end

    TEMPLATE = TransferDashboard::Html.erb(<<~'HTML')
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <title>Media</title>
      <style>
<%= TransferDashboard::BASE_CSS %>
        .badge.active { background: var(--accent); }
        .badge.nas { background: #7a5cc9; }
        .tiles .tile .sub { overflow-wrap: break-word; word-break: normal; }
        .tile.nas .value::before { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin: 0 8px 4px 0; content: ""; background: #7a5cc9; }
        .filters { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 20px 0 10px; }
        .filters input, .filters select { font: inherit; font-size: 13px; padding: 5px 8px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface-2); color: var(--text); }
        .filters input { flex: 1 1 160px; min-width: 120px; }
        .filters .count { font-size: 12px; color: var(--text-3); margin-left: auto; }
        li.group { grid-template-columns: 26px minmax(0, 1fr); }
        ul.files { list-style: none; margin: 6px 0 0; padding: 0; }
        ul.files li { display: block; padding: 5px 0 0; border-top: 1px dashed var(--border); margin-top: 5px; font-size: 13px; word-break: break-word; }
        ul.files li.hidden, li.group.hidden { display: none; }
        .frees { color: var(--warning); }
        .warn { color: var(--critical); font-size: 12px; }
        .kind { display: inline-block; font-size: 11px; padding: 0 6px; border-radius: 4px; border: 1px solid var(--border); color: var(--text-2); vertical-align: 1px; }
      </style>
      </head>
      <body>
      <main>
        <h1>Media</h1>
        <p class="sub">Generated <%= h(@inv.generated_at.strftime('%a %b %e, %H:%M')) %> · <a href="../">Transfers</a> · <b>Media</b></p>

        <section class="tiles" aria-label="Totals">
          <div class="tile"><div class="label">Local library</div><div class="value"><%= h(size_label(@totals['library_bytes'])) %></div><div class="sub"><%= @totals['library_files'] %> files in <%= h(@inv.media_root) %></div></div>
          <div class="tile ok"><div class="label">In Transmission</div><div class="value"><%= @inv.rpc_error ? '?' : h(size_label(@totals['torrent_bytes'])) %></div><div class="sub"><%= @inv.rpc_error ? 'unreachable' : "#{@totals['torrents']} torrents, #{@totals['seeding']} seeding" %></div></div>
          <div class="tile"><div class="label">Stored once</div><div class="value"><%= h(size_label(@totals['shared_bytes'])) %></div><div class="sub">library hardlinks into the downloads</div></div>
          <div class="tile <%= @totals['reclaimable_bytes'].positive? ? 'low' : '' %>"><div class="label">Reclaimable</div><div class="value"><%= h(size_label(@totals['reclaimable_bytes'])) %></div><div class="sub">by removing <%= @totals['reclaimable_torrents'] %> finished torrents with their data</div></div>
          <div class="tile nas"><div class="label">On the NAS</div><div class="value"><%= @totals['on_nas'] %></div><div class="sub">files, per the transfer log</div></div>
          <div class="tile <%= @totals['warnings'].positive? ? 'fail' : 'ok' %>"><div class="label">Needs attention</div><div class="value"><%= @totals['warnings'] %></div><div class="sub">symlinks, duplicates, missing files</div></div>
        </section>

        <%- if @inv.rpc_error -%>
        <div class="notice"><b>Transmission unreachable.</b> Only the library is listed. <div class="msg"><%= h(@inv.rpc_error) %></div></div>
        <%- end -%>
        <%- unless @inv.library_errors.empty? -%>
        <div class="notice"><b>Could not read part of the library.</b><%- @inv.library_errors.each do |e| -%><div class="msg"><%= h(e) %></div><%- end -%></div>
        <%- end -%>

        <div class="filters" id="filters">
          <input type="search" id="q" placeholder="Search names" aria-label="Search names">
          <select id="state" aria-label="State">
            <option value="">Any state</option>
            <%- MediaInventory::STATE_LABELS.each do |value, label| -%>
            <option value="<%= h(value) %>"><%= h(label) %></option>
            <%- end -%>
            <option value="attention">Needs attention</option>
          </select>
          <select id="kind" aria-label="Kind">
            <option value="">TV and movies</option>
            <option value="tv">TV</option>
            <option value="movie">Movies</option>
            <option value="unknown">Unrecognised</option>
          </select>
          <select id="nas" aria-label="NAS">
            <option value="">NAS: any</option>
            <option value="yes">On the NAS</option>
            <option value="no">Not on the NAS</option>
          </select>
          <select id="sort" aria-label="Sort">
            <option value="when">Newest first</option>
            <option value="oldest">Oldest first</option>
            <option value="size">Largest first</option>
            <option value="frees">Most reclaimable first</option>
            <option value="ratio">Lowest ratio first</option>
            <option value="name">By name</option>
          </select>
          <span class="count" id="count"></span>
        </div>

        <%- if @inv.groups.empty? -%>
        <div class="empty">Nothing found: no video in Transmission and nothing under <%= h(@inv.media_root) %>/tv or /movies.</div>
        <%- else -%>
        <ul class="list" id="groups">
          <%- @inv.groups.each do |g| -%>
          <%- t = g.torrent -%>
          <li class="group" data-name="<%= h(g.name.downcase) %>" data-size="<%= g.size %>" data-frees="<%= g.frees_if_removed %>" data-when="<%= g.when ? g.when.to_i : 0 %>" data-ratio="<%= t ? t['ratio'] : 99 %>">
            <span class="badge <%= h(STATE_CLASSES.fetch(g.state, 'other')) %>" aria-label="<%= h(MediaDashboard.state_label(g.state)) %>"><%= STATE_GLYPHS.fetch(g.state, '?') %></span>
            <div class="body">
              <div class="name"><%= h(g.name) %> <span class="kind"><%= h(MediaDashboard.kind_label(g.kind)) %></span></div>
              <div class="meta"><b><%= h(MediaDashboard.state_label(g.state)) %></b><%- if g.size.positive? -%> · <%= h(size_label(g.size)) %><%- end -%><%- if t -%> · <%= h(t['status']) %><%- if t['complete'] -%>, ratio <%= h(t['ratio']) %> · finished <%= when_html(g.when) %><%- else -%>, <%= t['percent'] %>% · added <%= when_html(g.when) %><%- end -%><%- else -%> · <%= when_html(g.when) %><%- end -%><%- if g.frees_if_removed >= SHOW_FREES_FROM -%> · <span class="frees">removing frees <%= h(size_label(g.frees_if_removed)) %></span><%- end -%></div>
              <%- if t && t['error'] -%><div class="warn">Transmission: <%= h(t['error']) %></div><%- end -%>
              <ul class="files">
                <%- g.items.each do |i| -%>
                <li class="file" data-name="<%= h(i.name.downcase) %>" data-state="<%= h(i.state) %>" data-kind="<%= h(i.kind) %>" data-nas="<%= i.on_nas? ? 'yes' : 'no' %>" data-attention="<%= i.warnings.empty? ? 'no' : 'yes' %>">
                  <%- if g.items.count > 1 || i.name != File.basename(t ? t['name'] : i.name) -%><div><%= h(i.name) %> · <%= h(size_label(i.size)) %><%- if i.extracted -%> · extracted from an archive<%- end -%></div><%- end -%>
                  <div class="msg"><%= h(library_label(i)) %><%- if nas_label(i) -%> · <%= h(nas_label(i)) %><%- end -%><%- if i.in_transmission? && i.in_library? && i.frees_if_removed >= SHOW_FREES_FROM -%> · <span class="frees">removing the download frees <%= h(size_label(i.frees_if_removed)) %></span><%- end -%></div>
                  <%- i.warnings.each do |w| -%><div class="warn">! <%= h(w) %></div><%- end -%>
                </li>
                <%- end -%>
              </ul>
            </div>
          </li>
          <%- end -%>
        </ul>
        <%- end -%>

        <footer>
          <%= @inv.groups.count %> torrents and library files · TV and movies only; the NAS at <%= h(@inv.nas_root) %> is not scanned
        </footer>
      </main>
      <script>
      (function () {
        var groups = Array.prototype.slice.call(document.querySelectorAll('li.group'));
        var list = document.getElementById('groups');
        var controls = ['q', 'state', 'kind', 'nas', 'sort'].map(function (id) { return document.getElementById(id); });
        var saved = {};
        try { saved = JSON.parse(localStorage.getItem('media-filters') || '{}'); } catch (e) { saved = {}; }
        controls.forEach(function (c) { if (saved[c.id] !== undefined) { c.value = saved[c.id]; } });

        function apply() {
          var q = controls[0].value.toLowerCase(), state = controls[1].value, kind = controls[2].value, nas = controls[3].value, sort = controls[4].value;
          var shown = 0, total = 0;
          groups.forEach(function (g) {
            var any = false;
            Array.prototype.forEach.call(g.querySelectorAll('li.file'), function (f) {
              total += 1;
              var ok = (!q || f.getAttribute('data-name').indexOf(q) >= 0 || g.getAttribute('data-name').indexOf(q) >= 0) &&
                       (!state || (state === 'attention' ? f.getAttribute('data-attention') === 'yes' : f.getAttribute('data-state') === state)) &&
                       (!kind || f.getAttribute('data-kind') === kind) &&
                       (!nas || f.getAttribute('data-nas') === nas);
              f.className = ok ? 'file' : 'file hidden';
              if (ok) { any = true; shown += 1; }
            });
            g.className = any ? 'group' : 'group hidden';
          });
          var key = { when: ['when', -1], oldest: ['when', 1], size: ['size', -1], frees: ['frees', -1], ratio: ['ratio', 1], name: ['name', 1] }[sort] || ['when', -1];
          groups.slice().sort(function (a, b) {
            var x = a.getAttribute('data-' + key[0]), y = b.getAttribute('data-' + key[0]);
            if (key[0] !== 'name') { x = parseFloat(x); y = parseFloat(y); }
            return (x < y ? -1 : x > y ? 1 : 0) * key[1];
          }).forEach(function (g) { if (list) { list.appendChild(g); } });
          document.getElementById('count').textContent = shown + ' of ' + total + ' files';
          var state = {};
          controls.forEach(function (c) { state[c.id] = c.value; });
          try { localStorage.setItem('media-filters', JSON.stringify(state)); } catch (e) { /* private mode */ }
        }
        controls.forEach(function (c) { c.addEventListener('input', apply); c.addEventListener('change', apply); });
        apply();
      })();
      </script>
      </body>
      </html>
    HTML
  end
end
