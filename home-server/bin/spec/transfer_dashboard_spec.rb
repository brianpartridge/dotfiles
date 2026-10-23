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

  def build(records:, torrents: [], rpc_error: nil, session: { 'download-dir' => '/dl', 'download-dir-free-space' => 50e9.to_i }, disk: nil,
            queue: instance_double(JobQueue, jobs: []))
    log = instance_double(TransferLog, records: records)
    rpc = instance_double(TransmissionRPC)
    if rpc_error
      allow(rpc).to receive(:torrents).and_raise(TransmissionRPC::Error, rpc_error)
    else
      allow(rpc).to receive(:torrents).and_return(torrents)
      allow(rpc).to receive(:session).and_return(session)
    end
    disk_space = lambda { |dir| disk && dir == '/dl' ? disk.merge('directory' => dir) : nil }
    TransferDashboard::Report.new(log: log, rpc: rpc, now: now, disk_space: disk_space, queue: queue)
  end

  let(:roomy_disk) { { 'mount' => '/', 'total' => 1000e9.to_i, 'used' => 400e9.to_i, 'free' => 600e9.to_i } }

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

    it 'reports free space on the download volume from df' do
      r = build(records: [], disk: roomy_disk)
      expect(r.disk).to include('directory' => '/dl', 'mount' => '/', 'free' => 600e9.to_i, 'total' => 1000e9.to_i)
      expect(r.disk_level).to eq('ok')
    end

    it 'falls back to the free space Transmission reports when df cannot answer' do
      r = build(records: [])
      expect(r.disk).to eq('directory' => '/dl', 'mount' => nil, 'total' => nil, 'used' => nil, 'free' => 50e9.to_i)
      expect(r.disk_level).to eq('ok')
    end

    it 'has no disk figure without Transmission' do
      expect(build(records: [], rpc_error: 'nope').disk).to be_nil
    end

    it 'grades low and critical space' do
      expect(build(records: [], disk: roomy_disk.merge('free' => 120e9.to_i, 'used' => 880e9.to_i)).disk_level).to eq('low')
      expect(build(records: [], disk: roomy_disk.merge('free' => 30e9.to_i, 'used' => 970e9.to_i)).disk_level).to eq('critical')
      expect(build(records: [], session: { 'download-dir' => '/dl', 'download-dir-free-space' => 8e9.to_i }).disk_level).to eq('critical')
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
        expect(html).to include('Free on downloads volume', '50.0 GB', '/dl (as reported by Transmission)')
        expect(html).to include('RuntimeError: missing', 'env ... ruby x')
        expect(html).not_to include('<script src') # only the inline copy-button script
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

    it 'offers a promote button only on the newest library record of each torrent' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        recs = [
          { 'ts' => now.iso8601, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'promote', 'message' => 'Promoted',
            'destination' => '/nas/tv/a.mkv', 'torrent' => { 'name' => 'Already.Promoted', 'hash' => 'a' * 40 } },
          { 'ts' => (now - 60).iso8601, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'link', 'message' => 'Linked',
            'destination' => '/m/tv/a.mkv', 'torrent' => { 'name' => 'Already.Promoted', 'hash' => 'a' * 40 } },
          { 'ts' => (now - 120).iso8601, 'status' => 'ok', 'outcome' => 'movie', 'action' => 'extract_link', 'message' => 'Linked',
            'destination' => '/m/movies/b.mkv', 'torrent' => { 'name' => 'Film <1>', 'hash' => 'B' * 40 } },
          { 'ts' => (now - 180).iso8601, 'status' => 'other', 'outcome' => 'ebook', 'action' => 'none', 'message' => 'not filed',
            'torrent' => { 'name' => 'Book', 'hash' => 'c' * 40 } },
          { 'ts' => (now - 240).iso8601, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'link', 'message' => 'no hash',
            'destination' => '/m/tv/d.mkv', 'torrent' => { 'name' => 'Hashless' } }
        ]
        r = build(records: recs)
        expect(r.promotable?(recs[0])).to be false
        expect(r.promotable?(recs[1])).to be false # superseded by the promotion
        expect(r.promotable?(recs[2])).to be true
        expect(r.promotable?(recs[3])).to be false
        expect(r.promotable?(recs[4])).to be false
        TransferDashboard.generate(report: r, output: out, quiet: true)
        html = File.read(out, encoding: 'UTF-8')
        expect(html.scan('class="promote queue"').count).to eq(1)
        expect(html).to include(%(data-action="promote" data-hash="#{'B' * 40}" data-confirm="Copy &quot;Film &lt;1&gt;&quot; to the NAS))
        expect(html).to include('promoted to /nas/tv', "'X-Requested-With', 'transfers'", "action: button.getAttribute('data-action')")
      end
    end

    it 'treats only the newest of two records in the same second as current' do
      same = now.iso8601
      recs = [
        { 'ts' => same, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'link', 'message' => 'Linked on re-run',
          'destination' => '/m/tv/a.mkv', 'torrent' => { 'name' => 'Show', 'hash' => 'a' * 40 } },
        { 'ts' => same, 'status' => 'error', 'outcome' => 'error', 'message' => 'NoMethodError',
          'torrent' => { 'name' => 'Show', 'hash' => 'a' * 40 } }
      ]
      r = build(records: recs)
      expect(r.rerunnable?(recs[1])).to be false
      expect(r.promotable?(recs[0])).to be true
    end

    it 'offers Re-run finish on the newest failed done-script record and on unhandled torrents' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        recs = [
          { 'ts' => now.iso8601, 'status' => 'error', 'outcome' => 'error', 'message' => 'NoMethodError',
            'torrent' => { 'name' => 'Failed.Show', 'hash' => 'a' * 40, 'directory' => '/dl' } },
          { 'ts' => (now - 60).iso8601, 'status' => 'error', 'outcome' => 'error', 'message' => 'older failure',
            'torrent' => { 'name' => 'Failed.Show', 'hash' => 'a' * 40, 'directory' => '/dl' } },
          { 'ts' => (now - 120).iso8601, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'link', 'message' => 'Linked',
            'destination' => '/m/tv/b.mkv', 'torrent' => { 'name' => 'Fine', 'hash' => 'b' * 40 } },
          { 'ts' => (now - 180).iso8601, 'status' => 'error', 'outcome' => 'tv', 'action' => 'promote', 'job' => 'job-1',
            'message' => 'Promote failed', 'torrent' => { 'name' => 'Worker.Failure', 'hash' => 'c' * 40 } },
          { 'ts' => (now - 240).iso8601, 'status' => 'error', 'outcome' => 'no_torrent', 'message' => 'No torrent in environment' }
        ]
        never = { 'name' => 'Never.Handled', 'hashString' => 'd' * 40, 'percentDone' => 1.0, 'doneDate' => (now - 3600).to_i,
                  'status' => 6, 'totalSize' => 1, 'downloadDir' => '/dl' }
        r = build(records: recs, torrents: [never])
        expect(recs.map { |rec| r.rerunnable?(rec) }).to eq([true, false, false, false, false])
        TransferDashboard.generate(report: r, output: out, quiet: true)
        html = File.read(out, encoding: 'UTF-8')
        expect(html.scan('data-action="rerun_finish"').count).to eq(2)
        expect(html).to include(%(data-action="rerun_finish" data-hash="#{'a' * 40}" data-confirm="Run the done-script again for &quot;Failed.Show&quot;?">Re-run finish</button>))
        expect(html).to include(%(data-action="rerun_finish" data-hash="#{'d' * 40}"))
      end
    end

    it 'lists jobs with their state and log, opening the log of a failed one' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        done = instance_double(JobQueue::Job, id: '20260925-115900-promote-aaaa', request: { 'action' => 'promote', 'hash' => 'a' * 40, 'via' => 'dashboard' },
                                              status: { 'state' => 'done', 'action' => 'promote', 'subject' => 'a' * 40, 'message' => 'Promoted a.mkv to /nas/tv',
                                                        'started_at' => (now - 120).iso8601, 'finished_at' => (now - 60).iso8601 },
                                              log_tail: "11:59:00 Started\n12:00:00 Done\n")
        failed = instance_double(JobQueue::Job, id: '20260925-113000-promote-bbbb', request: { 'action' => 'promote', 'hash' => 'b' * 40 },
                                                status: { 'state' => 'failed', 'action' => 'promote', 'subject' => 'b' * 40, 'message' => 'Promoter::NotMounted: NAS is not mounted',
                                                          'started_at' => (now - 1800).iso8601, 'finished_at' => (now - 1799).iso8601 },
                                                log_tail: "11:30:00 FAILED: Promoter::NotMounted: NAS is not mounted <x>\n")
        queued = instance_double(JobQueue::Job, id: '20260925-120000-promote-cccc', request: { 'action' => 'promote', 'hash' => 'c' * 40 }, status: nil, log_tail: '')
        r = build(records: [], queue: instance_double(JobQueue, jobs: [queued, done, failed]))
        expect(r.jobs.map { |j| j['state'] }).to eq(%w[queued done failed])
        expect(r.running_jobs.count).to eq(1)
        expect(r.failed_jobs.count).to eq(1)
        TransferDashboard.generate(report: r, output: out, quiet: true)
        html = File.read(out, encoding: 'UTF-8')
        expect(html).to include('<h2>Jobs</h2>', 'Promoted a.mkv to /nas/tv', 'NAS is not mounted &lt;x&gt;', 'via dashboard')
        expect(html.scan('<details open>').count).to eq(1)
        expect(html).to include('class="badge running" aria-label="queued"', 'class="badge done"', 'class="badge failed"')
        expect(TransferDashboard.text(r)).to include('JOBS:', 'failed  20260925-113000-promote-bbbb  Promoter::NotMounted')
      end
    end

    it 'shows no jobs section when the queue has never been used' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        r = build(records: [], queue: JobQueue.new(queue_dir: File.join(dir, 'q'), jobs_dir: File.join(dir, 'j')))
        TransferDashboard.generate(report: r, output: out, quiet: true)
        expect(File.read(out, encoding: 'UTF-8')).not_to include('<h2>Jobs</h2>')
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

    it 'gives every command a copy button' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        rec = [{ 'ts' => now.iso8601, 'status' => 'other', 'outcome' => 'ebook', 'message' => 'eBook: 1 epub; not filed',
                 'torrent' => { 'name' => 'Book' }, 'repro' => 'env A=1 ruby x', 'file_command' => 'env A=1 ruby x --file-other' }]
        TransferDashboard.generate(report: build(records: rec), output: out, quiet: true)
        html = File.read(out, encoding: 'UTF-8')
        expect(html.scan('<button type="button" class="copy">Copy</button>').count).to eq(2)
        expect(html).to include('<pre>env A=1 ruby x --file-other</pre>', '<pre>env A=1 ruby x</pre>')
        expect(html).to include("execCommand('copy')")
      end
    end

    it 'shows the used meter and mount when df answered' do
      with_tmpdir do |dir|
        out = File.join(dir, 'index.html')
        TransferDashboard.generate(report: build(records: [], disk: roomy_disk), output: out, quiet: true)
        html = File.read(out, encoding: 'UTF-8')
        expect(html).to include('600.0 GB', '400.0 GB of 1.00 TB used · /', 'aria-valuenow="40"', 'class="tile ok"')
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

    it 'prints free space' do
      expect(TransferDashboard.text(build(records: [], disk: roomy_disk))).to include('Free space: 600.0 GB of 1.00 TB on /')
      expect(TransferDashboard.text(build(records: [], disk: roomy_disk.merge('free' => 30e9.to_i)))).to include('(LOW)')
    end

    it 'prints the filing command for unfiled downloads' do
      rec = [{ 'ts' => now.iso8601, 'status' => 'other', 'outcome' => 'ebook', 'message' => 'eBook: 1 epub; not filed',
               'torrent' => { 'name' => 'Book' }, 'file_command' => 'env A=1 ruby x --file-other' }]
      expect(TransferDashboard.text(build(records: rec))).to include('file: env A=1 ruby x --file-other')
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
