# frozen_string_literal: true

require 'rspec'
require 'torrent_handler'
require_relative 'spec_helper_transfers'

describe Torrent do
  it 'is nil without a name and directory' do
    expect(Torrent.from_env({})).to be_nil
    expect(Torrent.from_env('TR_TORRENT_NAME' => 'x')).to be_nil
    expect(Torrent.from_env('TR_TORRENT_NAME' => '', 'TR_TORRENT_DIR' => '/tmp')).to be_nil
  end

  it 'reads the Transmission environment' do
    t = Torrent.from_env('TR_TORRENT_NAME' => 'Show.S01E02.720p', 'TR_TORRENT_DIR' => '/dl',
                         'TR_TORRENT_HASH' => 'ABC', 'TR_TORRENT_ID' => '7')
    expect(t.path).to eq('/dl/Show.S01E02.720p')
    expect(t.to_h).to eq('name' => 'Show.S01E02.720p', 'directory' => '/dl', 'hash' => 'ABC', 'id' => '7')
  end

  it 'lists files recursively, ignoring dotfiles, for names with glob characters' do
    with_tmpdir do |dir|
      name = 'Show [2019] S01E01'
      touch(File.join(dir, name, 'a.mkv'))
      touch(File.join(dir, name, 'Subs', 'a.srt'))
      touch(File.join(dir, name, '.DS_Store'))
      files = Torrent.new(name, dir).files
      expect(files.map { |f| f.sub("#{dir}/#{name}/", '') }).to eq(['Subs/a.srt', 'a.mkv'])
    end
  end

  it 'treats a single-file torrent as one file' do
    with_tmpdir do |dir|
      touch(File.join(dir, 'movie.mkv'))
      expect(Torrent.new('movie.mkv', dir).files).to eq([File.join(dir, 'movie.mkv')])
    end
  end
end

describe MediaFile do
  it 'recognises media extensions, including mp4, and rejects samples' do
    with_tmpdir do |dir|
      expect(MediaFile.valid?(touch(File.join(dir, 'a.mkv')))).to be true
      expect(MediaFile.valid?(touch(File.join(dir, 'a.MP4')))).to be true
      expect(MediaFile.valid?(touch(File.join(dir, 'a.m4v')))).to be true
      expect(MediaFile.valid?(touch(File.join(dir, 'a.nfo')))).to be false
      expect(MediaFile.valid?(touch(File.join(dir, 'a-sample.mkv')))).to be false
      expect(MediaFile.valid?(File.join(dir, 'missing.mkv'))).to be false
    end
  end

  it 'counts a multi-volume rar set once' do
    with_tmpdir do |dir|
      files = %w[x.part01.rar x.part02.rar x.part03.rar y.rar].map { |f| touch(File.join(dir, f)) }
      expect(MediaFile.primary_rars(files).map { |f| File.basename(f) }).to eq(%w[y.rar x.part01.rar])
    end
  end
end

describe Outcome do
  it 'serialises exceptions' do
    e = RuntimeError.new('boom')
    e.set_backtrace(['a:1', 'b:2'])
    o = Outcome.error('failed', exception: e)
    expect(o.error?).to be true
    expect(o.to_h['error']).to eq('class' => 'RuntimeError', 'message' => 'boom', 'backtrace' => ['a:1', 'b:2'])
  end
end

describe TorrentHandler do
  around do |example|
    with_tmpdir do |dir|
      @dl = File.join(dir, 'downloads')
      @tv = File.join(dir, 'tv')
      @movies = File.join(dir, 'movies')
      FileUtils.mkdir_p([@dl, @tv, @movies])
      example.run
    end
  end

  def entries(dir)
    (Dir.entries(dir) - %w[. ..]).sort
  end

  def handler(name)
    TorrentHandler.new(Torrent.new(name, @dl), tv_directory: @tv, movie_directory: @movies, logger: null_logger)
  end

  it 'hardlinks a TV episode so the torrent keeps seeding' do
    name = 'Some.Show.S02E05.720p.HDTV-GRP'
    media = touch(File.join(@dl, name, "#{name}.mkv"), 'video')
    touch(File.join(@dl, name, "#{name}.nfo"))
    o = handler(name).run!
    expect(o.status).to eq('ok')
    expect(o.outcome).to eq('tv')
    expect(o.action).to eq('link')
    expect(o.destination).to eq(File.join(@tv, "#{name}.mkv"))
    expect(File.symlink?(o.destination)).to be false
    expect(File.identical?(media, o.destination)).to be true
    expect(File.stat(media).nlink).to eq(2)
    expect(o.message).to start_with('Linked')
  end

  it 'leaves the library copy intact when the torrent data is deleted, and vice versa' do
    name = 'Some.Movie.1999.1080p.BluRay-GRP'
    media = touch(File.join(@dl, name, "#{name}.mkv"), 'video')
    library = handler(name).run!.destination
    FileUtils.rm_rf(File.join(@dl, name))
    expect(File.read(library)).to eq('video')
    touch(media, 'video')
    File.unlink(library)
    expect(File.read(media)).to eq('video')
  end

  it 'falls back to the file name when the torrent name does not classify' do
    touch(File.join(@dl, 'grp-ss0205', 'Some.Show.S02E05.720p.mkv'))
    o = handler('grp-ss0205').run!
    expect(o.outcome).to eq('tv')
    expect(o.destination).to eq(File.join(@tv, 'Some.Show.S02E05.720p.mkv'))
  end

  it 'hardlinks a movie' do
    name = 'Some.Movie.1999.1080p.BluRay-GRP'
    media = touch(File.join(@dl, name, "#{name}.mkv"))
    o = handler(name).run!
    expect(o.outcome).to eq('movie')
    expect(o.action).to eq('link')
    expect(File.identical?(media, o.destination)).to be true
  end

  it 'is idempotent, and upgrades a symlink from the old scheme in place' do
    name = 'Some.Movie.1999.1080p.BluRay-GRP'
    media = touch(File.join(@dl, name, "#{name}.mkv"))
    expect(handler(name).run!.message).to start_with('Linked')
    expect(handler(name).run!.message).to start_with('Already linked')
    library = File.join(@movies, "#{name}.mkv")
    File.unlink(library)
    File.symlink(media, library)
    expect(handler(name).run!.message).to start_with('Relinked')
    expect(File.symlink?(library)).to be false
    expect(File.identical?(media, library)).to be true
    File.unlink(library)
    File.symlink('/nowhere', library)
    expect(handler(name).run!.message).to start_with('Replaced stale link with')
    expect(File.identical?(media, library)).to be true
  end

  it 'falls back to a symlink across volumes and says so' do
    name = 'Some.Movie.1999.1080p.BluRay-GRP'
    media = touch(File.join(@dl, name, "#{name}.mkv"))
    allow(File).to receive(:link).and_raise(Errno::EXDEV)
    o = handler(name).run!
    expect(o.action).to eq('symlink')
    expect(o.message).to start_with('Symlinked').and include('different volume')
    expect(File.symlink?(o.destination)).to be true
    expect(File.readlink(o.destination)).to eq(media)
    expect(Dir.glob(File.join(@movies, '*.linking'))).to eq([])
  end

  it 'raises, rather than silently failing, when a different file blocks the link' do
    name = 'Some.Movie.1999.1080p.BluRay-GRP'
    touch(File.join(@dl, name, "#{name}.mkv"))
    touch(File.join(@movies, "#{name}.mkv"), 'something else')
    expect { handler(name).run! }.to raise_error(/different file/)
  end

  it 'raises when the destination volume is missing' do
    name = 'Some.Show.S02E05.720p.HDTV-GRP'
    touch(File.join(@dl, name, "#{name}.mkv"))
    FileUtils.rm_rf(@tv)
    expect { handler(name).run! }.to raise_error(/missing/)
  end

  it 'treats torrents with no media as other, not a failure' do
    name = 'Some.Show.S02E05.720p.HDTV-GRP'
    touch(File.join(@dl, name, 'readme.txt'))
    o = handler(name).run!
    expect(o.status).to eq('other')
    expect(o.other?).to be true
    expect(o.outcome).to eq('no_media')
  end

  it 'files every episode of a season pack by its own name' do
    name = 'Some.Show.S02.720p.HDTV-GRP'
    %w[Some.Show.S02E01.720p.mkv Some.Show.S02E02.720p.mkv].each { |f| touch(File.join(@dl, name, f)) }
    o = handler(name).run!
    expect(o.status).to eq('ok')
    expect(o.outcome).to eq('tv')
    expect(o.action).to eq('link')
    expect(o.media_file).to eq(File.join(@dl, name))
    expect(o.destination).to eq(@tv)
    expect(o.message).to eq("Linked 2 of 2 media files (tv) into #{@tv}")
    expect(entries(@tv)).to eq(%w[Some.Show.S02E01.720p.mkv Some.Show.S02E02.720p.mkv])
    expect(File.stat(File.join(@tv, 'Some.Show.S02E01.720p.mkv')).nlink).to eq(2)
  end

  it 'does not let a year in a pack name turn episodes into movies' do
    name = 'Some.Show.2019.S01.1080p-GRP'
    touch(File.join(@dl, name, 'Some.Show.S01E01.mkv'))
    touch(File.join(@dl, name, 'Some.Show.S01E02.mkv'))
    expect(handler(name).run!.outcome).to eq('tv')
    expect(entries(@movies)).to be_empty
  end

  it 'files the recognisable part of a set and reports the rest as skipped' do
    name = 'Some.Show.S02.720p.HDTV-GRP'
    touch(File.join(@dl, name, 'Some.Show.S02E01.720p.mkv'))
    touch(File.join(@dl, name, 'bonus-featurette.mkv'))
    o = handler(name).run!
    expect(o.status).to eq('ok')
    expect(o.outcome).to eq('tv')
    expect(o.action).to eq('link')
    expect(o.message).to eq("Linked 1 of 2 media files (tv) into #{@tv}; skipped: bonus-featurette.mkv")
    expect(entries(@tv)).to eq(['Some.Show.S02E01.720p.mkv'])
  end

  it 'is other when nothing in a set is recognisable' do
    name = 'Concert.Bundle-GRP'
    touch(File.join(@dl, name, 'part-a.mkv'))
    touch(File.join(@dl, name, 'part-b.mkv'))
    o = handler(name).run!
    expect(o.status).to eq('other')
    expect(o.outcome).to eq('unknown_media')
    expect(o.message).to eq('None of 2 media files recognised as TV or a movie: part-a.mkv, part-b.mkv')
    expect(entries(@tv)).to eq([])
  end

  it 'is other for a single file that is neither TV nor a movie' do
    name = 'Random.Thing.WEB-GRP'
    touch(File.join(@dl, name, 'thing.mkv'))
    o = handler(name).run!
    expect(o.status).to eq('other')
    expect(o.outcome).to eq('unknown_media')
    expect(o.media_file).to end_with('thing.mkv')
  end

  context 'books and audio' do
    def other(name, *files)
      files.each { |f| touch(File.join(@dl, name, f)) }
      handler(name).run!
    end

    it 'recognises an eBook' do
      o = other('Some.Author.Some.Title.2019.epub-GRP', 'title.epub', 'title.mobi', 'cover.jpg')
      expect(o.status).to eq('other')
      expect(o.outcome).to eq('ebook')
      expect(o.message).to eq('eBook: 1 epub, 1 mobi')
      expect(o.media_file).to eq(File.join(@dl, 'Some.Author.Some.Title.2019.epub-GRP'))
    end

    it 'recognises a comic, and a comic that comes with a PDF' do
      expect(other('Hero.Comic.v02.2020.Digital-GRP', 'hero-02.cbz', 'hero-02.pdf').outcome).to eq('comic')
      expect(other('Other.Comic-GRP', 'x.cbr').message).to eq('Comic: 1 cbr')
    end

    it 'treats a lone PDF as an eBook unless the name looks like a comic' do
      expect(other('Some.Textbook.3rd.Edition-GRP', 'book.pdf').outcome).to eq('ebook')
      expect(other('Hero.Comic.012.2020.Digital-GRP', 'hero.pdf').outcome).to eq('comic')
      expect(other('Hero.Comic.#12-GRP', 'hero.pdf').outcome).to eq('comic')
    end

    it 'recognises an audiobook by m4b, or by a set of mp3s with nothing saying otherwise' do
      expect(other('Some.Book-GRP', 'book.m4b').outcome).to eq('audiobook')
      o = other('Another.Book-GRP', '01.mp3', '02.mp3', '03.mp3', 'cover.jpg')
      expect(o.outcome).to eq('audiobook')
      expect(o.message).to eq('Audiobook: 3 mp3')
    end

    it 'tells music from audiobooks' do
      # lossless formats and rip sidecars are music
      expect(other('Artist.Album.2020-GRP', '01.flac', '02.flac').outcome).to eq('music')
      expect(other('Artist.Album.2020-GRP', '01.mp3', '02.mp3', '03.mp3', 'album.cue', 'album.log').outcome).to eq('music')
      # the release name decides when the files do not
      expect(other('Artist.Album.2020.320.MP3-GRP', '01.mp3', '02.mp3', '03.mp3').outcome).to eq('music')
      expect(other('Artist.Discography.1990-2020-GRP', '01.mp3', '02.mp3', '03.mp3').outcome).to eq('music')
      expect(other('Some.Author.Some.Book.Unabridged.64kbps-GRP', '01.mp3', '02.mp3', '03.mp3').outcome).to eq('audiobook')
      # an audiobook hint in the name wins over a music hint
      expect(other('Live.Free.Unabridged-GRP', '01.mp3', '02.mp3', '03.mp3').outcome).to eq('audiobook')
      # chapter-style file names mean a book
      expect(other('Some.Book-GRP', 'Chapter 01.mp3', 'Chapter 02.mp3', 'Chapter 03.mp3', 'intro.mp3').outcome).to eq('audiobook')
      expect(other('Some.Book-GRP', 'Part 1.m4a', 'Part 2.m4a').outcome).to eq('audiobook')
      # one or two tracks with no other evidence is music
      o = other('Single.Track-GRP', 'song.mp3')
      expect(o.outcome).to eq('music')
      expect(o.message).to eq('Music: 1 mp3')
    end

    it 'prefers comics over eBooks over audio when mixed, and video over all' do
      expect(other('Mixed-GRP', 'a.cbz', 'a.epub', 'a.pdf').outcome).to eq('comic')
      expect(other('Mixed2-GRP', 'a.epub', '01.mp3', '02.mp3', '03.mp3').outcome).to eq('ebook')
      expect(other('Mixed3-GRP', 'book.m4b', '01.flac').outcome).to eq('audiobook')
      expect(other('Some.Show.S01E01-GRP', 'ep.mkv', 'notes.pdf').outcome).to eq('tv')
    end

    it 'still calls unrelated files no_media' do
      expect(other('Software-GRP', 'setup.exe', 'readme.txt').outcome).to eq('no_media')
    end
  end

  context 'archives' do
    let(:name) { 'Some.Show.S02E05.720p.HDTV-GRP' }

    it 'raises when unrar is not installed' do
      touch(File.join(@dl, name, "#{name}.rar"))
      h = handler(name)
      allow(h).to receive(:system).and_return(nil)
      expect { h.run! }.to raise_error(/unrar not found/)
    end

    it 'raises when unrar fails' do
      touch(File.join(@dl, name, "#{name}.rar"))
      h = handler(name)
      allow(h).to receive(:system) { `exit 3`; false }
      expect { h.run! }.to raise_error(/unrar exited with status 3/)
    end

    it 'files the media that extraction produced' do
      touch(File.join(@dl, name, "#{name}.rar"))
      h = handler(name)
      allow(h).to receive(:system) do |*_args, **_opts|
        touch(File.join(@dl, name, "#{name}.mkv"))
        true
      end
      o = h.run!
      expect(o.outcome).to eq('tv')
      expect(o.action).to eq('extract_link')
    end

    it 'files a set that extraction produced' do
      touch(File.join(@dl, name, "#{name}.rar"))
      h = handler(name)
      allow(h).to receive(:system) do |*_args, **_opts|
        touch(File.join(@dl, name, 'Some.Show.S02E05.mkv'))
        touch(File.join(@dl, name, 'Some.Show.S02E06.mkv'))
        true
      end
      o = h.run!
      expect(o.outcome).to eq('tv')
      expect(o.action).to eq('extract_link')
      expect(o.message).to start_with('Linked 2 of 2 media files')
    end

    it 'warns when extraction produced nothing useful' do
      touch(File.join(@dl, name, "#{name}.rar"))
      h = handler(name)
      allow(h).to receive(:system).and_return(true)
      o = h.run!
      expect(o.outcome).to eq('no_media')
      expect(o.message).to start_with('Archive')
    end

    it 'classifies what an archive extracted to when it is not video' do
      touch(File.join(@dl, name, "#{name}.rar"))
      h = handler(name)
      allow(h).to receive(:system) do |*_args, **_opts|
        touch(File.join(@dl, name, 'book.epub'))
        true
      end
      o = h.run!
      expect(o.outcome).to eq('ebook')
      expect(o.message).to eq("Archive #{name}.rar contained no video; eBook: 1 epub")
    end
  end
end
