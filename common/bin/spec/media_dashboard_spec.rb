# frozen_string_literal: true

require 'rspec'
require 'media_dashboard'
require_relative 'spec_helper_transfers'

describe MediaDashboard do
  include TransferSpecHelpers

  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  # A small inventory: one seeding episode in the library, one unfiled movie, one library-only file.
  def inventory(dir, rpc_error: nil)
    dl = File.join(dir, 'downloads')
    media = File.join(dir, 'Media')
    ep = touch(File.join(dl, 'Show.S01E01/Show.S01E01.mkv'), 'e' * 2_000_000)
    FileUtils.mkdir_p(File.join(media, 'tv'))
    File.link(ep, File.join(media, 'tv', 'Show.S01E01.mkv'))
    touch(File.join(dl, 'Film.2010/Film.2010.mkv'), 'f' * 3_000_000)
    touch(File.join(media, 'movies', 'Alone <b>.2000.mkv'), 'a' * 1_000_000)
    torrents = [
      { 'id' => 1, 'name' => 'Show.S01E01', 'hashString' => 'a' * 40, 'percentDone' => 1.0, 'isFinished' => true, 'status' => 6,
        'doneDate' => (now - 86_400).to_i, 'addedDate' => (now - 90_000).to_i, 'downloadDir' => dl, 'totalSize' => 2_000_000,
        'error' => 0, 'errorString' => '', 'uploadRatio' => 1.25,
        'files' => [{ 'name' => 'Show.S01E01/Show.S01E01.mkv', 'length' => 2_000_000, 'bytesCompleted' => 2_000_000 }] },
      { 'id' => 2, 'name' => 'Film.2010', 'hashString' => 'b' * 40, 'percentDone' => 1.0, 'isFinished' => true, 'status' => 6,
        'doneDate' => (now - 10 * 86_400).to_i, 'addedDate' => (now - 11 * 86_400).to_i, 'downloadDir' => dl, 'totalSize' => 3_000_000,
        'error' => 0, 'errorString' => 'Tracker gave up', 'uploadRatio' => 0.1,
        'files' => [{ 'name' => 'Film.2010/Film.2010.mkv', 'length' => 3_000_000, 'bytesCompleted' => 3_000_000 }] }
    ]
    rpc = instance_double(TransmissionRPC)
    if rpc_error
      allow(rpc).to receive(:torrents).and_raise(TransmissionRPC::Error, rpc_error)
    else
      allow(rpc).to receive(:torrents).and_return(torrents)
    end
    log = instance_double(TransferLog, records: [])
    MediaInventory::Inventory.new(rpc: rpc, log: log, media_root: media, nas_root: '/Volumes/Media', now: now, nas_check: ->(_) { nil })
  end

  describe '.generate' do
    it 'writes the page and media.json next to the transfers dashboard' do
      with_tmpdir do |dir|
        out = File.join(dir, 'www', 'media', 'index.html')
        expect { MediaDashboard.generate(inventory: inventory(dir), output: out) }.to output(/Wrote/).to_stdout
        html = File.read(out, encoding: 'UTF-8')
        expect(html).to include('<title>Media</title>', '<a href="../">Transfers</a>')
        expect(html).to include('Seeding, in library', 'Downloaded, not in library', 'Library only, not in Transmission')
        expect(html).to include('~/Media/tv (hardlink)', 'ratio 1.25', 'Transmission: Tracker gave up')
        expect(html).to include('removing frees 3 MB') # the unfiled movie
        expect(html).not_to include('removing frees 2 MB') # the hardlinked episode frees nothing
        expect(html).to include('Alone &lt;b&gt;.2000.mkv')
        expect(html).not_to include('Alone <b>')
        expect(html).to include('data-state="unfiled"', 'data-kind="movie"', 'data-nas="no"')
        expect(html).to include('data-age="1"', 'data-age="10"', '<option value="over100">Over 100 days</option>', '<option value="under30">Under 30 days</option>')
        expect(html).to include("localStorage.setItem('media-filters'")
        json = JSON.parse(File.read(File.join(dir, 'www', 'media', 'media.json')))
        expect(json['totals']).to include('library_bytes' => 3_000_000, 'torrent_bytes' => 5_000_000, 'shared_bytes' => 2_000_000,
                                          'reclaimable_bytes' => 3_000_000, 'reclaimable_torrents' => 1)
        expect(json['groups'].map { |g| g['name'] }).to contain_exactly('Show.S01E01', 'Film.2010', 'Alone <b>.2000.mkv')
        expect(File.exist?("#{out}.tmp")).to be false
      end
    end

    it 'offers the right actions per row, with the facts the confirmation needs' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        jobs = [{ 'id' => 'j1', 'state' => 'failed', 'action' => 'remove_torrent', 'subject' => 'b' * 40, 'message' => 'RuntimeError: still downloading', 'request' => {} },
                { 'id' => 'j2', 'state' => 'running', 'action' => 'promote', 'request' => { 'path' => '/m/tv/x.mkv' } }]
        MediaDashboard.generate(inventory: inventory(dir), output: out, quiet: true, jobs: jobs)
        html = File.read(out, encoding: 'UTF-8')
        # the seeding episode: remove with a keep box, promote and unlink for its library file
        expect(html).to include(%(data-action="remove_torrent" data-hash="#{'a' * 40}" data-name="Show.S01E01" data-frees="0" data-library="1" data-fragile="no"))
        expect(html).to include('<input type="checkbox" class="keep" checked> keep the 1 library file</label>')
        expect(html).to include(%(data-action="promote" data-path="#{File.join(dir, 'Media', 'tv', 'Show.S01E01.mkv')}" data-name="Show.S01E01.mkv" data-size="2000000"))
        expect(html).to include(%(data-action="unlink_library" data-path="#{File.join(dir, 'Media', 'tv', 'Show.S01E01.mkv')}" data-name="Show.S01E01.mkv" data-elsewhere="the download" data-size="2000000">Remove from library))
        # the unfiled movie: remove only, no keep box
        expect(html).to include(%(data-action="remove_torrent" data-hash="#{'b' * 40}" data-name="Film.2010" data-frees="3000000" data-library="0"))
        expect(html.scan('class="keep"').count).to eq(1)
        # the library-only file: promote, and a delete that says it is the only copy
        expect(html).to include(%(data-name="Alone &lt;b&gt;.2000.mkv" data-elsewhere="" data-size="1000000">Delete from library))
        expect(html.scan('data-action="unlink_library"').count).to eq(2)
        expect(html.scan('data-action="promote"').count).to eq(2)
        expect(html).to include("'X-Requested-With', 'transfers'", 'Files are deleted, not moved to the Trash.', 'This is the only copy')
        expect(html).to include('<b>Jobs:</b> 1 running, 1 failed in the last 2', 'RuntimeError: still downloading', 'promote x.mkv')
      end
    end

    it 'shows a notice and only the library when Transmission is unreachable' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        MediaDashboard.generate(inventory: inventory(dir, rpc_error: 'refused'), output: out, quiet: true)
        html = File.read(out, encoding: 'UTF-8')
        expect(html).to include('Transmission unreachable', 'refused', 'Library only, not in Transmission')
        expect(html).not_to include('Film.2010')
      end
    end

    it 'puts the page under the transfers dashboard directory by default' do
      expect(MediaDashboard.output_path).to eq('/Library/WebServer/Documents/transfers/media/index.html')
      expect(MediaDashboard.output_path('/x/y.html')).to eq('/x/y.html')
      begin
        ENV['TRANSFER_DASHBOARD'] = '/srv/t/index.html'
        expect(MediaDashboard.output_path).to eq('/srv/t/media/index.html')
      ensure
        ENV.delete('TRANSFER_DASHBOARD')
      end
    end
  end

  describe '.text' do
    it 'summarises for the terminal' do
      with_tmpdir do |dir|
        text = MediaDashboard.text(inventory(dir))
        expect(text).to include('Library: 3 MB in 2 files', 'Transmission: 5 MB in 2 torrents, 2 seeding', 'Stored once', 'Reclaimable by removing 1 finished torrents: 3 MB')
        expect(text).to include('Seeding, in library', 'Show.S01E01', '[library (hardlink)]', 'removing frees 3 MB')
      end
    end
  end
end
