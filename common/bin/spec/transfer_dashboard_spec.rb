# frozen_string_literal: true

require 'rspec'
require 'transfer_dashboard'
require_relative 'spec_helper_transfers'

describe TransferDashboard do
  let(:now) { Time.utc(2026, 9, 25, 12, 0, 0) }

  def torrent(name, hash, done: 1.0, done_at: now - 3600, status: 6, error: 0)
    { 'name' => name, 'hashString' => hash, 'percentDone' => done, 'doneDate' => done_at.to_i,
      'addedDate' => (done_at - 7200).to_i, 'status' => status, 'downloadDir' => '/dl',
      'totalSize' => 1_500_000_000, 'error' => error, 'errorString' => '' }
  end

  def build(records:, torrents: [], rpc_error: nil)
    log = instance_double(TransferLog, records: records)
    rpc = instance_double(TransmissionRPC)
    if rpc_error
      allow(rpc).to receive(:torrents).and_raise(TransmissionRPC::Error, rpc_error)
    else
      allow(rpc).to receive(:torrents).and_return(torrents)
    end
    TransferDashboard::Report.new(log: log, rpc: rpc, now: now)
  end

  let(:records) do
    [
      { 'ts' => (now - 600).iso8601, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'copy',
        'message' => 'Copied a.mkv to /tv', 'media_file' => '/dl/a/a.mkv', 'destination' => '/tv/a.mkv',
        'torrent' => { 'name' => 'Show.S01E01', 'hash' => 'AAA' }, 'duration_s' => 1.2, 'notified' => true },
      { 'ts' => (now - 2 * 86_400).iso8601, 'status' => 'error', 'outcome' => 'error', 'action' => 'none',
        'message' => 'RuntimeError: Destination directory is missing', 'torrent' => { 'name' => 'Film.2001', 'hash' => 'bbb' },
        'error' => { 'class' => 'RuntimeError', 'message' => 'missing', 'backtrace' => ['x.rb:1'] }, 'repro' => 'env ... ruby x' },
      { 'ts' => (now - 10 * 86_400).iso8601, 'status' => 'warning', 'outcome' => 'no_media', 'action' => 'none',
        'message' => 'No media files found', 'torrent' => { 'name' => 'Old.Thing', 'hash' => 'ccc' } },
      { 'ts' => (now - 12 * 86_400).iso8601, 'status' => 'ok', 'outcome' => 'movie', 'action' => 'link',
        'message' => 'older record for the same torrent', 'torrent' => { 'name' => 'Show.S01E01', 'hash' => 'AAA' } }
    ]
  end

  describe TransferDashboard::Report do
    it 'counts by status within a window' do
      r = build(records: records)
      expect(r.counts(TransferDashboard::WEEK)).to eq('ok' => 1, 'other' => 0, 'error' => 1)
      expect(r.counts(TransferDashboard::DAY)).to eq('ok' => 1, 'other' => 0, 'error' => 0)
    end

    it 'reads legacy warning records as other' do
      r = build(records: records)
      expect(r.records.map { |x| x['status'] }).to eq(%w[ok error other ok])
      expect(r.counts(30 * 86_400)['other']).to eq(1)
    end

    it 'flags complete torrents with no record, matching by hash (any case) or name' do
      torrents = [
        torrent('Show.S01E01', 'aaa'),
        torrent('Film.2001 renamed', 'BBB'),
        torrent('Old.Thing', 'zzz'),
        torrent('Never.Handled', 'ddd'),
        torrent('Still.Downloading', 'eee', done: 0.4, status: 4)
      ]
      r = build(records: records, torrents: torrents)
      expect(r.unhandled.map { |t| t['name'] }).to eq(['Never.Handled'])
      expect(r.active.map { |t| t['name'] }).to eq(['Still.Downloading'])
      expect(r.completed.count).to eq(4)
    end

    it 'ignores complete torrents older than the unhandled window' do
      old_done = torrent('Ancient.Thing', 'old1', done_at: now - 8 * 86_400)
      added_long_ago = torrent('Verified.Later', 'old2', done_at: now - 30 * 86_400).merge('doneDate' => 0)
      fresh_no_done_date = torrent('Added.Complete', 'new1', done_at: now - 3600).merge('doneDate' => 0)
      r = build(records: [], torrents: [old_done, added_long_ago, fresh_no_done_date, torrent('Recent', 'new2')])
      expect(r.unhandled.map { |t| t['name'] }).to eq(%w[Recent Added.Complete])
      expect(r.unhandled(window: 365 * 86_400).count).to eq(4)
    end

    it 'survives an unreachable Transmission' do
      r = build(records: records, rpc_error: 'Errno::ECONNREFUSED')
      expect(r.rpc_error).to match(/ECONNREFUSED/)
      expect(r.unhandled).to eq([])
    end
  end

  describe '.generate' do
    it 'writes a self-contained page' do
      with_tmpdir do |dir|
        out = File.join(dir, 'sub', 'index.html')
        r = build(records: records, torrents: [torrent('Never.Handled', 'ddd'), torrent('Dl', 'e', done: 0.5, status: 4)])
        expect { TransferDashboard.generate(report: r, output: out) }.to output(/Wrote/).to_stdout
        html = File.read(out)
        expect(html).to include('Show.S01E01', 'Never.Handled', 'last 7 days, never handled', 'unhandled, 7 days', 'In progress', '50%')
        expect(html).to include('RuntimeError: missing', 'env ... ruby x')
        expect(html).not_to include('<script')
        expect(File.exist?("#{out}.tmp")).to be false
      end
    end

    it 'writes transfers.json with the latest record per torrent' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        TransferDashboard.generate(report: build(records: records), output: out, quiet: true)
        json = JSON.parse(File.read(File.join(dir, 'transfers.json')))
        expect(json['unhandled_window_days']).to eq(7)
        expect(json['dashboard_url']).to eq(TransferDashboard.url)
        expect(json['by_hash'].keys).to eq(%w[aaa bbb ccc])
        expect(json['by_hash']['aaa']['outcome']).to eq('tv') # newest wins over the older movie record
        expect(json['by_hash']['ccc']['status']).to eq('other') # legacy warning normalised
        expect(json['by_name']['Film.2001']).to include('status' => 'error', 'message' => 'RuntimeError: Destination directory is missing')
        expect(File.exist?(File.join(dir, 'transfers.json.tmp'))).to be false
      end
    end

    it 'escapes HTML in torrent names' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        rec = [{ 'ts' => now.iso8601, 'status' => 'ok', 'outcome' => 'tv', 'message' => 'm',
                 'torrent' => { 'name' => '<b>evil</b>' } }]
        TransferDashboard.generate(report: build(records: rec), output: out, quiet: true)
        html = File.read(out)
        expect(html).to include('&lt;b&gt;evil&lt;/b&gt;')
        expect(html).not_to include('<b>evil</b>')
      end
    end

    it 'shows a notice when Transmission is unreachable' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        TransferDashboard.generate(report: build(records: [], rpc_error: 'nope'), output: out, quiet: true)
        expect(File.read(out)).to include('Transmission unreachable', 'No transfers recorded yet')
      end
    end
  end

  describe '.text' do
    it 'summarises for the terminal' do
      text = TransferDashboard.text(build(records: records, torrents: [torrent('Never.Handled', 'ddd')]))
      expect(text).to include('1 filed, 0 other, 1 failed', 'UNHANDLED', 'Never.Handled', 'Show.S01E01', '10m ago')
      expect(text).to include('Destination directory is missing')
    end
  end

  describe '.digest' do
    around do |example|
      @sent = []
      Notify.transport = ->(p) { @sent << p; FakeResponse.new('200', '') }
      with_tmpdir do |dir|
        conf = File.join(dir, 'p.json')
        File.write(conf, '{"token":"t","user":"u"}')
        Notify.config_path = conf
        example.run
      end
    ensure
      Notify.transport = nil
      Notify.config_path = nil
    end

    it 'sends a low-priority summary on a quiet day' do
      expect(TransferDashboard.digest(build(records: []))).to be true
      expect(@sent.last['title']).to eq('Transfers, last 24h: 0 filed, 0 other, 0 failed')
      expect(@sent.last['message']).to include('no transfers')
      expect(@sent.last['priority']).to eq(-1)
    end

    it 'links to the dashboard' do
      TransferDashboard.digest(build(records: []))
      expect(@sent.last['url']).to eq(TransferDashboard.url)
      expect(@sent.last['url_title']).to eq('Open the dashboard')
    end

    it 'sends high priority when something is unhandled' do
      r = build(records: records, torrents: [torrent('Never.Handled', 'ddd')])
      TransferDashboard.digest(r)
      expect(@sent.last['priority']).to eq(1)
      expect(@sent.last['message']).to include('✓ Show.S01E01', 'no record', '• Never.Handled')
    end
  end

  describe '.url' do
    it 'derives a Bonjour address from the hostname' do
      allow(Socket).to receive(:gethostname).and_return('theater-mac')
      expect(TransferDashboard.url).to eq('http://theater-mac.local/transfers/')
      allow(Socket).to receive(:gethostname).and_return('theater-mac.local')
      expect(TransferDashboard.url).to eq('http://theater-mac.local/transfers/')
    end

    it 'can be overridden' do
      ENV['TRANSFER_DASHBOARD_URL'] = 'http://example.test/x/'
      expect(TransferDashboard.url).to eq('http://example.test/x/')
    ensure
      ENV.delete('TRANSFER_DASHBOARD_URL')
    end
  end

  it 'formats relative times' do
    expect(TransferDashboard.relative_time(now - 30, now)).to eq('just now')
    expect(TransferDashboard.relative_time(now - 90, now)).to eq('1m ago')
    expect(TransferDashboard.relative_time(now - 7200, now)).to eq('2h ago')
    expect(TransferDashboard.relative_time(now - 3 * 86_400, now)).to eq('3d ago')
    expect(TransferDashboard.relative_time(nil, now)).to eq('unknown')
  end
end
