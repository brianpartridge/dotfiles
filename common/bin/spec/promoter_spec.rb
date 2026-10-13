# frozen_string_literal: true

require 'rspec'
require 'promoter'
require_relative 'spec_helper_transfers'

describe Promoter do
  include TransferSpecHelpers

  def setup(dir, mounted: true)
    @downloads = File.join(dir, 'downloads')
    @media = File.join(dir, 'Media')
    @nas = File.join(dir, 'nas')
    FileUtils.mkdir_p([@downloads, @media, @nas])
    Promoter.new(nas_root: @nas, media_root: @media, logger: null_logger, mounted: -> { mounted })
  end

  it 'copies a hardlinked library file to the NAS and leaves the download seeding' do
    with_tmpdir do |dir|
      p = setup(dir)
      download = touch(File.join(@downloads, 'Show.S01E01', 'Show.S01E01.mkv'), 'bytes' * 100)
      library = File.join(@media, 'tv', 'Show.S01E01.mkv')
      FileUtils.mkdir_p(File.dirname(library))
      File.link(download, library)

      result = p.promote(library)
      target = File.join(@nas, 'tv', 'Show.S01E01.mkv')
      expect(result).to eq('source' => library, 'target' => target, 'bytes' => 500, 'still_seeding' => true, 'kept_link' => false)
      expect(File.read(target)).to eq('bytes' * 100)
      expect(File.exist?(library)).to be false
      expect(File.exist?(download)).to be true
      expect(Dir.glob(File.join(@nas, '**', '*.copying'))).to be_empty
    end
  end

  it 'follows a symlinked library file and can leave a symlink to the NAS behind' do
    with_tmpdir do |dir|
      p = setup(dir)
      download = touch(File.join(@downloads, 'Film.mkv'), 'film')
      library = File.join(@media, 'movies', 'Film.mkv')
      FileUtils.mkdir_p(File.dirname(library))
      File.symlink(download, library)

      result = p.promote(library, keep_link: true)
      target = File.join(@nas, 'movies', 'Film.mkv')
      expect(result).to include('still_seeding' => true, 'kept_link' => true)
      expect(File.read(target)).to eq('film')
      expect(File.symlink?(library)).to be true
      expect(File.readlink(library)).to eq(target)
      expect(File.exist?(download)).to be true
    end
  end

  it 'moves a plain file that has no other links' do
    with_tmpdir do |dir|
      p = setup(dir)
      library = touch(File.join(@media, 'tv', 'Lone.mkv'), 'lone')
      result = p.promote(library)
      expect(result['still_seeding']).to be false
      expect(File.exist?(library)).to be false
      expect(File.read(File.join(@nas, 'tv', 'Lone.mkv'))).to eq('lone')
    end
  end

  it 'skips the copy when the NAS already has the same bytes' do
    with_tmpdir do |dir|
      p = setup(dir)
      library = touch(File.join(@media, 'tv', 'Dup.mkv'), 'same')
      touch(File.join(@nas, 'tv', 'Dup.mkv'), 'same')
      expect(FileUtils).not_to receive(:cp)
      p.promote(library)
      expect(File.exist?(library)).to be false
    end
  end

  it 'refuses when the NAS is not mounted, leaving everything alone' do
    with_tmpdir do |dir|
      p = setup(dir, mounted: false)
      library = touch(File.join(@media, 'tv', 'X.mkv'))
      expect { p.promote(library) }.to raise_error(Promoter::NotMounted, /not mounted/)
      expect(File.exist?(library)).to be true
      expect(Dir.glob(File.join(@nas, '**', '*'))).to be_empty
    end
  end

  it 'refuses paths outside the library and missing files' do
    with_tmpdir do |dir|
      p = setup(dir)
      outside = touch(File.join(@downloads, 'X.mkv'))
      expect { p.promote(outside) }.to raise_error(RuntimeError, /not under/)
      expect { p.promote(File.join(@media, 'tv', 'gone.mkv')) }.to raise_error(RuntimeError, /does not exist/)
    end
  end

  it 'does not remove the local file when the copy comes up short' do
    with_tmpdir do |dir|
      p = setup(dir)
      library = touch(File.join(@media, 'tv', 'Short.mkv'), 'full length')
      allow(FileUtils).to receive(:cp) { |_src, dst| File.write(dst, 'full') }
      expect { p.promote(library) }.to raise_error(RuntimeError, /Copy incomplete/)
      expect(File.exist?(library)).to be true
      expect(File.exist?(File.join(@nas, 'tv', 'Short.mkv'))).to be false
    end
  end

  describe '#library_files' do
    it 'returns the single destination of a file record' do
      with_tmpdir do |dir|
        p = setup(dir)
        library = touch(File.join(@media, 'tv', 'A.mkv'))
        expect(p.library_files('destination' => library)).to eq([library])
        expect(p.library_files('destination' => File.join(@media, 'tv', 'gone.mkv'))).to eq([])
        expect(p.library_files({})).to eq([])
      end
    end

    it 'finds the files of a season pack by identity with the torrent' do
      with_tmpdir do |dir|
        p = setup(dir)
        pack = File.join(@downloads, 'Show.S01')
        e1 = touch(File.join(pack, 'Show.S01E01.mkv'), 'e1')
        e2 = touch(File.join(pack, 'Sub', 'Show.S01E02.mkv'), 'e2')
        touch(File.join(pack, 'sample.mkv'), 'sample')
        tv = File.join(@media, 'tv')
        FileUtils.mkdir_p(tv)
        File.link(e1, File.join(tv, 'Show.S01E01.mkv'))
        File.symlink(e2, File.join(tv, 'Show.S01E02.mkv'))
        touch(File.join(tv, 'Other.S01E01.mkv'), 'other') # someone else's, not this torrent

        record = { 'destination' => tv, 'media_file' => pack }
        expect(p.library_files(record).sort).to eq([File.join(tv, 'Show.S01E01.mkv'), File.join(tv, 'Show.S01E02.mkv')])

        results = p.promote_record(record)
        expect(results.map { |r| File.basename(r['target']) }.sort).to eq(%w[Show.S01E01.mkv Show.S01E02.mkv])
        expect(results.map { |r| r['still_seeding'] }).to eq([true, true])
        expect(File.exist?(File.join(tv, 'Other.S01E01.mkv'))).to be true
        expect(File.exist?(e1) && File.exist?(e2)).to be true
      end
    end

    it 'raises when a record has nothing left to promote' do
      with_tmpdir do |dir|
        p = setup(dir)
        expect { p.promote_record({ 'destination' => File.join(@media, 'tv', 'gone.mkv') }) }.to raise_error(RuntimeError, /Nothing to promote/)
      end
    end
  end

  describe '#mounted?' do
    it 'needs a mount point exactly at the NAS root' do
      with_tmpdir do |dir|
        nas = File.join(dir, 'Volumes', 'Media')
        FileUtils.mkdir_p(nas)
        p = Promoter.new(nas_root: nas, media_root: dir, logger: null_logger)
        allow(TransferDashboard::DiskSpace).to receive(:for).with(nas).and_return('mount' => '/', 'free' => 1)
        expect(p.mounted?).to be false
        allow(TransferDashboard::DiskSpace).to receive(:for).with(nas).and_return('mount' => nas, 'free' => 1)
        expect(p.mounted?).to be true
        allow(TransferDashboard::DiskSpace).to receive(:for).with(nas).and_return(nil)
        expect(p.mounted?).to be false
      end
    end
  end
end
