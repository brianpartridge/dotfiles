# frozen_string_literal: true

require 'rspec'
require 'media_remover'
require_relative 'spec_helper_transfers'

describe MediaRemover do
  include TransferSpecHelpers

  let(:now) { Time.utc(2026, 10, 1, 12, 0, 0) }

  # A fake Transmission: torrents live in @torrents and remove deletes the declared files, like the real one.
  def fake_rpc
    rpc = instance_double(TransmissionRPC)
    allow(rpc).to receive(:torrents) { @torrents }
    allow(rpc).to receive(:remove) do |ids, delete_data: false|
      @removed << [ids, delete_data]
      @torrents.select { |t| ids.include?(t['id']) }.each do |t|
        t['files'].each { |f| FileUtils.rm_f(File.join(t['downloadDir'], f['name'])) } if delete_data
      end
      @torrents.reject! { |t| ids.include?(t['id']) }
      {}
    end
    rpc
  end

  def layout(dir)
    @dl = File.join(dir, 'downloads')
    @media = File.join(dir, 'Media')
    @tv = File.join(@media, 'tv')
    FileUtils.mkdir_p([@dl, @tv])
    @torrents = []
    @removed = []
    @rpc = fake_rpc
    log = instance_double(TransferLog, records: [])
    inventory = lambda { MediaInventory::Inventory.new(rpc: @rpc, log: log, media_root: @media, nas_root: '/Volumes/Media', now: now, nas_check: ->(_) { nil }) }
    MediaRemover.new(rpc: @rpc, media_root: @media, logger: null_logger, inventory: inventory, sleeper: ->(_) {})
  end

  def add_torrent(name, files, status: 6, done: 1.0)
    files.each { |f, bytes| touch(File.join(@dl, f), 'x' * bytes) }
    id = @torrents.count + 1
    @torrents << { 'id' => id, 'name' => name, 'hashString' => name.downcase.tr('.', '').ljust(40, '0')[0, 40], 'percentDone' => done,
                   'isFinished' => done >= 1.0, 'status' => status, 'doneDate' => (now - 86_400).to_i, 'addedDate' => (now - 90_000).to_i,
                   'downloadDir' => @dl, 'totalSize' => files.inject(0) { |s, (_, b)| s + b }, 'error' => 0, 'errorString' => '',
                   'files' => files.map { |f, b| { 'name' => f, 'length' => b, 'bytesCompleted' => b } }, 'uploadRatio' => 2.0 }
    @torrents.last['hashString']
  end

  it 'removes a torrent with its data and the hardlinked library file keeps the bytes' do
    with_tmpdir do |dir|
      r = layout(dir)
      hash = add_torrent('Show.S01E01', [['Show.S01E01/Show.S01E01.mkv', 1000], ['Show.S01E01/notes.nfo', 20]])
      library = File.join(@tv, 'Show.S01E01.mkv')
      File.link(File.join(@dl, 'Show.S01E01/Show.S01E01.mkv'), library)

      result = r.remove_torrent(hash)
      expect(@removed).to eq([[[1], true]])
      expect(result).to include('torrent' => 'Show.S01E01', 'freed' => 20, 'kept' => [library], 'removed_library' => [], 'ratio' => 2.0)
      expect(File.read(library)).to eq('x' * 1000)
      expect(File.exist?(File.join(@dl, 'Show.S01E01'))).to be false # emptied folder removed
    end
  end

  it 'removes the library files too when asked, and counts their bytes as freed' do
    with_tmpdir do |dir|
      r = layout(dir)
      hash = add_torrent('Film.2001', [['Film.2001/Film.2001.mkv', 500]])
      library = File.join(@media, 'movies', 'Film.2001.mkv')
      FileUtils.mkdir_p(File.dirname(library))
      File.link(File.join(@dl, 'Film.2001/Film.2001.mkv'), library)
      result = r.remove_torrent(hash, keep_library: false)
      expect(result).to include('freed' => 500, 'kept' => [], 'removed_library' => [library])
      expect(File.exist?(library)).to be false
    end
  end

  it 'turns a library symlink into a hardlink before the download goes' do
    with_tmpdir do |dir|
      r = layout(dir)
      hash = add_torrent('Old.1999', [['Old.1999/old.mkv', 300]])
      library = File.join(@tv, 'old.mkv')
      File.symlink(File.join(@dl, 'Old.1999/old.mkv'), library)
      result = r.remove_torrent(hash)
      expect(File.symlink?(library)).to be false
      expect(File.read(library)).to eq('x' * 300)
      expect(result['freed']).to eq(0) # the bytes moved to the library's name rather than going away
      expect(Dir.glob(File.join(@tv, '*.relinking'))).to be_empty
    end
  end

  it 'removes an extracted video Transmission never knew about, and leaves other files alone' do
    with_tmpdir do |dir|
      r = layout(dir)
      hash = add_torrent('Rar.2004', [['Rar.2004/rar.rar', 10]])
      extracted = touch(File.join(@dl, 'Rar.2004/Rar.2004.mkv'), 'v' * 400)
      File.link(extracted, File.join(@media, 'movies', 'Rar.2004.mkv').tap { |p| FileUtils.mkdir_p(File.dirname(p)) })
      touch(File.join(@dl, 'Rar.2004/README.txt'), 'keep me')
      r.remove_torrent(hash)
      expect(File.exist?(extracted)).to be false
      expect(File.exist?(File.join(@dl, 'Rar.2004/README.txt'))).to be true # not ours to delete
      expect(File.read(File.join(@media, 'movies', 'Rar.2004.mkv'))).to eq('v' * 400)
    end
  end

  it 'refuses a torrent that is still downloading or unknown' do
    with_tmpdir do |dir|
      r = layout(dir)
      hash = add_torrent('Partial.S01E01', [['Partial.S01E01/p.mkv', 10]], status: 4, done: 0.3)
      expect { r.remove_torrent(hash) }.to raise_error(RuntimeError, /still downloading \(30%\)/)
      expect { r.remove_torrent('f' * 40) }.to raise_error(RuntimeError, /No torrent with hash/)
      expect(@removed).to be_empty
    end
  end

  it 'warns but carries on when Transmission does not delete in time' do
    with_tmpdir do |dir|
      r = layout(dir)
      hash = add_torrent('Slow.S01E01', [['Slow.S01E01/s.mkv', 10]])
      allow(@rpc).to receive(:remove) { @torrents.clear; {} } # removed, files left behind
      stub_const('MediaRemover::SETTLE_SECONDS', 0)
      expect { r.remove_torrent(hash) }.not_to raise_error
      expect(File.exist?(File.join(@dl, 'Slow.S01E01/s.mkv'))).to be true
    end
  end

  describe '#unlink_library' do
    it 'removes the library entries of a torrent, or one path, never outside the library' do
      with_tmpdir do |dir|
        r = layout(dir)
        hash = add_torrent('Show.S02', [['Show.S02/Show.S02E01.mkv', 10], ['Show.S02/Show.S02E02.mkv', 10]])
        e1 = File.join(@tv, 'Show.S02E01.mkv')
        e2 = File.join(@tv, 'Show.S02E02.mkv')
        File.link(File.join(@dl, 'Show.S02/Show.S02E01.mkv'), e1)
        File.link(File.join(@dl, 'Show.S02/Show.S02E02.mkv'), e2)
        expect(r.unlink_library(hash: hash)).to eq('removed_library' => [e1, e2])
        expect(File.exist?(e1) || File.exist?(e2)).to be false
        expect(File.exist?(File.join(@dl, 'Show.S02/Show.S02E01.mkv'))).to be true

        lone = touch(File.join(@tv, 'Lone.mkv'))
        expect(r.unlink_library(path: lone)).to eq('removed_library' => [lone])
        expect { r.unlink_library(path: File.join(@dl, 'Show.S02/Show.S02E01.mkv')) }.to raise_error(RuntimeError, /not under/)
        expect { r.unlink_library(hash: hash) }.to raise_error(RuntimeError, /Nothing in the local library/)
      end
    end
  end
end
