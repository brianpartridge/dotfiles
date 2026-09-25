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
        'message' => 'No media files found', 'torrent' => { 'name' => 'Old.Thing', 'hash' => 'ccc' } }
    ]
  end

  describe TransferDashboard::Report do
    it 'counts by status within a window' do
      r = build(records: records)
      expect(r.counts(TransferDashboard::WEEK)).to eq('ok' => 1, 'warning' => 0, 'error' => 1)
      expect(r.counts(TransferDashboard::DAY)).to eq('ok' => 1, 'warning' => 0, 'error' => 0)
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
        expect(html).to include('Show.S01E01', 'Never.Handled', 'never handled', 'In progress', '50%')
        expect(html).to include('RuntimeError: missing', 'env ... ruby x')
        expect(html).not_to include('<script')
        expect(File.exist?("#{out}.tmp")).to be false
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
      expect(text).to include('1 ok, 0 attention, 1 failed', 'UNHANDLED', 'Never.Handled', 'Show.S01E01', '10m ago')
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
      expect(@sent.last['title']).to eq('Transfers, last 24h: 0 ok, 0 attention, 0 failed')
      expect(@sent.last['message']).to include('no transfers')
      expect(@sent.last['priority']).to eq(-1)
    end

    it 'sends high priority when something is unhandled' do
      r = build(records: records, torrents: [torrent('Never.Handled', 'ddd')])
      TransferDashboard.digest(r)
      expect(@sent.last['priority']).to eq(1)
      expect(@sent.last['message']).to include('✓ Show.S01E01', 'no record', '• Never.Handled')
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
