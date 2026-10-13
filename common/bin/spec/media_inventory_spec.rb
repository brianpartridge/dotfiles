# frozen_string_literal: true

require 'rspec'
require 'media_inventory'
require_relative 'spec_helper_transfers'

describe MediaInventory::Inventory do
  include TransferSpecHelpers

  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  # A scratch layout: downloads/ for Transmission, Media/{tv,movies} for the library.
  def layout(dir)
    @dl = File.join(dir, 'downloads')
    @media = File.join(dir, 'Media')
    @tv = File.join(@media, 'tv')
    @movies = File.join(@media, 'movies')
    FileUtils.mkdir_p([@dl, @tv, @movies])
  end

  def torrent(name, files, status: 6, done: 1.0, ratio: 1.5, hash: nil, size: nil, done_at: now - 86_400)
    files = files.map { |f, len| { 'name' => f, 'length' => len, 'bytesCompleted' => (len * done).to_i } }
    { 'id' => 1, 'name' => name, 'hashString' => hash || name.downcase.tr('.', '') .ljust(40, '0')[0, 40],
      'percentDone' => done, 'isFinished' => done >= 1.0, 'status' => status, 'doneDate' => done >= 1.0 ? done_at.to_i : 0,
      'addedDate' => (done_at - 3600).to_i, 'downloadDir' => @dl,
      'totalSize' => size || files.inject(0) { |s, f| s + f['length'] }, 'error' => 0, 'errorString' => '',
      'files' => files, 'uploadRatio' => ratio }
  end

  def download(rel, bytes)
    touch(File.join(@dl, rel), 'x' * bytes)
  end

  def hardlink(download, library)
    FileUtils.mkdir_p(File.dirname(library))
    File.link(download, library)
    library
  end

  def build(torrents: [], records: [], rpc_error: nil, nas_check: ->(_) { nil })
    rpc = instance_double(TransmissionRPC)
    if rpc_error
      allow(rpc).to receive(:torrents).and_raise(TransmissionRPC::Error, rpc_error)
    else
      allow(rpc).to receive(:torrents).with(fields: MediaInventory::TORRENT_FIELDS).and_return(torrents)
    end
    log = instance_double(TransferLog, records: records)
    MediaInventory::Inventory.new(rpc: rpc, log: log, media_root: @media, nas_root: '/Volumes/Media', now: now, nas_check: nas_check)
  end

  it 'matches a hardlinked episode to its torrent and knows removing it frees only the extras' do
    with_tmpdir do |dir|
      layout(dir)
      ep = download('Show.S01E01.720p/Show.S01E01.720p.mkv', 1000)
      download('Show.S01E01.720p/Show.S01E01.720p.nfo', 50)
      hardlink(ep, File.join(@tv, 'Show.S01E01.720p.mkv'))
      t = torrent('Show.S01E01.720p', [['Show.S01E01.720p/Show.S01E01.720p.mkv', 1000], ['Show.S01E01.720p/Show.S01E01.720p.nfo', 50]])
      inv = build(torrents: [t])

      expect(inv.groups.count).to eq(1)
      group = inv.groups.first
      item = group.items.first
      expect(group.items.count).to eq(1)
      expect(item.state).to eq('seeding')
      expect(item.kind).to eq('tv')
      expect(item.link).to eq('hardlink')
      expect(item.library_path).to eq(File.join(@tv, 'Show.S01E01.720p.mkv'))
      expect(item.frees_if_removed).to eq(0)
      expect(group.frees_if_removed).to eq(50)
      expect(group.size).to eq(1050)
      expect(item.warnings).to be_empty
      expect(group.torrent).to include('ratio' => 1.5, 'seeding' => true, 'complete' => true, 'status' => 'seeding')
    end
  end

  it 'tells seeding, stopped and downloading apart' do
    with_tmpdir do |dir|
      layout(dir)
      a = download('A.S01E01/A.S01E01.mkv', 10)
      hardlink(a, File.join(@tv, 'A.S01E01.mkv'))
      b = download('B.S01E01/B.S01E01.mkv', 10)
      hardlink(b, File.join(@tv, 'B.S01E01.mkv'))
      download('C.S01E01/C.S01E01.mkv', 5)
      inv = build(torrents: [
                    torrent('A.S01E01', [['A.S01E01/A.S01E01.mkv', 10]]),
                    torrent('B.S01E01', [['B.S01E01/B.S01E01.mkv', 10]], status: 0),
                    torrent('C.S01E01', [['C.S01E01/C.S01E01.mkv', 10]], status: 4, done: 0.5)
                  ])
      states = inv.groups.map { |g| [g.name, g.state] }.to_h
      expect(states).to eq('A.S01E01' => 'seeding', 'B.S01E01' => 'stopped', 'C.S01E01' => 'downloading')
      expect(inv.totals['states']).to eq('seeding' => 1, 'stopped' => 1, 'downloading' => 1)
    end
  end

  it 'lists a season pack file by file, with mixed states' do
    with_tmpdir do |dir|
      layout(dir)
      e1 = download('Show.S02/Show.S02E01.mkv', 100)
      download('Show.S02/Show.S02E02.mkv', 100)
      download('Show.S02/Sample/show.s02e01.sample.mkv', 5)
      hardlink(e1, File.join(@tv, 'Show.S02E01.mkv'))
      t = torrent('Show.S02', [['Show.S02/Show.S02E01.mkv', 100], ['Show.S02/Show.S02E02.mkv', 100], ['Show.S02/Sample/show.s02e01.sample.mkv', 5]])
      inv = build(torrents: [t])
      group = inv.groups.first
      expect(group.items.map(&:name)).to eq(%w[Show.S02E01.mkv Show.S02E02.mkv])
      expect(group.items.map(&:state)).to eq(%w[seeding unfiled])
      expect(group.state).to eq('mixed')
      expect(group.kind).to eq('tv')
      expect(group.frees_if_removed).to eq(105) # the unfiled episode and the sample
    end
  end

  it 'flags a symlinked library entry as depending on the download, and a separate copy as stored twice' do
    with_tmpdir do |dir|
      layout(dir)
      s = download('Sym.2001/Sym.2001.mkv', 100)
      File.symlink(s, File.join(@movies, 'Sym.2001.mkv'))
      download('Copy.2002/Copy.2002.mkv', 100)
      touch(File.join(@movies, 'Copy.2002.mkv'), 'y' * 100)
      inv = build(torrents: [torrent('Sym.2001', [['Sym.2001/Sym.2001.mkv', 100]]), torrent('Copy.2002', [['Copy.2002/Copy.2002.mkv', 100]])])
      copy, sym = inv.groups.sort_by(&:name).map { |g| g.items.first }
      expect(copy.link).to eq('copy')
      expect(copy.stored_bytes).to eq(200)
      expect(copy.frees_if_removed).to eq(100)
      expect(copy.warnings.first).to match(/Separate copy/)
      expect(sym.link).to eq('symlink')
      expect(sym.library_depends_on_download?).to be true
      expect(sym.warnings.first).to match(/would break/)
      expect(inv.groups.find { |g| g.name == 'Sym.2001' }.fragile?).to be true
      expect(inv.totals['reclaimable_bytes']).to eq(100) # the fragile one is left out
      expect(inv.totals['warnings']).to eq(2)
    end
  end

  it 'knows a torrent was promoted to the NAS from the log, without scanning the NAS' do
    with_tmpdir do |dir|
      layout(dir)
      download('Film.2003/Film.2003.mkv', 100)
      t = torrent('Film.2003', [['Film.2003/Film.2003.mkv', 100]])
      records = [
        { 'ts' => (now - 60).iso8601, 'status' => 'ok', 'outcome' => 'movie', 'action' => 'promote',
          'destinations' => ['/Volumes/Media/movies/Film.2003.mkv'], 'torrent' => { 'hash' => t['hashString'] } },
        { 'ts' => (now - 120).iso8601, 'status' => 'ok', 'outcome' => 'movie', 'action' => 'link',
          'destination' => File.join(@movies, 'Film.2003.mkv'), 'torrent' => { 'hash' => t['hashString'] } }
      ]
      checks = []
      inv = build(torrents: [t], records: records, nas_check: ->(p) { checks << p; true })
      item = inv.groups.first.items.first
      expect(item.state).to eq('promoted')
      expect(item.nas).to eq('path' => '/Volumes/Media/movies/Film.2003.mkv', 'promoted_at' => (now - 60).iso8601, 'verified' => true)
      expect(item.kind).to eq('movie')
      expect(checks).to eq(['/Volumes/Media/movies/Film.2003.mkv'])
      expect(inv.totals['on_nas']).to eq(1)
    end
  end

  it 'lists library files whose torrent is gone, and a kept link to the NAS' do
    with_tmpdir do |dir|
      layout(dir)
      touch(File.join(@tv, 'Gone.S01E01.mkv'), 'z' * 30)
      File.symlink('/Volumes/Media/movies/Kept.2000.mkv', File.join(@movies, 'Kept.2000.mkv'))
      File.symlink(File.join(dir, 'nowhere.mkv'), File.join(@movies, 'Broken.1999.mkv'))
      inv = build(torrents: [], nas_check: ->(_) { nil })
      by_name = inv.items.map { |i| [i.name, i] }.to_h
      expect(by_name.keys.sort).to eq(%w[Broken.1999.mkv Gone.S01E01.mkv Kept.2000.mkv])
      expect(by_name['Gone.S01E01.mkv'].state).to eq('library_only')
      expect(by_name['Gone.S01E01.mkv'].kind).to eq('tv')
      expect(by_name['Gone.S01E01.mkv'].size).to eq(30)
      expect(by_name['Kept.2000.mkv'].on_nas?).to be true
      expect(by_name['Kept.2000.mkv'].nas).to include('path' => '/Volumes/Media/movies/Kept.2000.mkv', 'verified' => nil)
      expect(by_name['Kept.2000.mkv'].warnings).to be_empty
      expect(by_name['Broken.1999.mkv'].on_disk).to be false
      expect(by_name['Broken.1999.mkv'].warnings.first).to match(/Broken symlink/)
      expect(inv.totals['library_files']).to eq(3)
      expect(inv.totals['library_bytes']).to eq(30)
    end
  end

  it 'includes a video extracted from an archive, which Transmission does not know about' do
    with_tmpdir do |dir|
      layout(dir)
      download('Rar.2004/rar.2004.rar', 10)
      ex = download('Rar.2004/Rar.2004.mkv', 500)
      hardlink(ex, File.join(@movies, 'Rar.2004.mkv'))
      download('Rar2.2005/rar2.rar', 10)
      download('Rar2.2005/Rar2.2005.mkv', 500)
      inv = build(torrents: [torrent('Rar.2004', [['Rar.2004/rar.2004.rar', 10]]), torrent('Rar2.2005', [['Rar2.2005/rar2.rar', 10]])])
      filed, unfiled = inv.groups.sort_by(&:name)
      expect(filed.items.first.extracted).to be true
      expect(filed.items.first.state).to eq('seeding')
      expect(filed.frees_if_removed).to eq(10) # the archive; the video stays with the library
      expect(unfiled.items.first.state).to eq('unfiled')
      expect(unfiled.frees_if_removed).to eq(510)
    end
  end

  it 'leaves out torrents with no video and recognises kinds from the log, the folder or the name' do
    with_tmpdir do |dir|
      layout(dir)
      download('Book/book.epub', 10)
      download('Logged/weird name.mkv', 10)
      download('Named.2006.1080p/named.mkv', 10)
      download('Series.1x02.720p/series.mkv', 10)
      download('Mystery/clip.mkv', 10)
      logged = torrent('Logged', [['Logged/weird name.mkv', 10]])
      inv = build(torrents: [
                    torrent('Book', [['Book/book.epub', 10]]), logged,
                    torrent('Named.2006.1080p', [['Named.2006.1080p/named.mkv', 10]]),
                    torrent('Series.1x02.720p', [['Series.1x02.720p/series.mkv', 10]]),
                    torrent('Mystery', [['Mystery/clip.mkv', 10]])
                  ],
                  records: [{ 'ts' => now.iso8601, 'status' => 'ok', 'outcome' => 'tv', 'action' => 'link', 'torrent' => { 'hash' => logged['hashString'] } }])
      kinds = inv.groups.map { |g| [g.name, g.kind] }.to_h
      expect(kinds).to eq('Logged' => 'tv', 'Named.2006.1080p' => 'movie', 'Series.1x02.720p' => 'tv', 'Mystery' => 'unknown')
    end
  end

  it 'survives an unreachable Transmission and reports it' do
    with_tmpdir do |dir|
      layout(dir)
      touch(File.join(@tv, 'Only.S01E01.mkv'), 'q')
      inv = build(rpc_error: 'connection refused')
      expect(inv.rpc_error).to eq('connection refused')
      expect(inv.items.map(&:state)).to eq(['library_only'])
    end
  end

  it 'serialises everything the page needs' do
    with_tmpdir do |dir|
      layout(dir)
      ep = download('S.S01E01/S.S01E01.mkv', 10)
      hardlink(ep, File.join(@tv, 'S.S01E01.mkv'))
      inv = build(torrents: [torrent('S.S01E01', [['S.S01E01/S.S01E01.mkv', 10]])])
      h = JSON.parse(JSON.generate(inv.to_h))
      expect(h['generated_at']).to eq(now.iso8601)
      expect(h['totals']).to include('library_bytes' => 10, 'torrent_bytes' => 10, 'shared_bytes' => 10, 'reclaimable_bytes' => 0, 'seeding' => 1)
      group = h['groups'].first
      expect(group).to include('name' => 'S.S01E01', 'kind' => 'tv', 'state' => 'seeding', 'size' => 10)
      expect(Time.parse(group['when'])).to eq(now - 86_400)
      expect(group['items'].first).to include('link' => 'hardlink', 'library_path' => File.join(@tv, 'S.S01E01.mkv'), 'frees_if_removed' => 0)
    end
  end
end
