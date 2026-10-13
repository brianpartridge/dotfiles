# frozen_string_literal: true

require 'rspec'
require 'transfers_worker'
require_relative 'spec_helper_transfers'

describe TransfersWorker do
  include TransferSpecHelpers

  HASH = 'c' * 40

  def setup(dir, mounted: true)
    @queue = JobQueue.new(queue_dir: File.join(dir, 'queue'), jobs_dir: File.join(dir, 'jobs'))
    @media = File.join(dir, 'Media')
    @nas = File.join(dir, 'nas')
    @log = TransferLog.new(File.join(dir, 'transfers.jsonl'))
    @pushes = []
    @refreshes = 0
    promoter = Promoter.new(nas_root: @nas, media_root: @media, logger: null_logger, mounted: -> { mounted })
    TransfersWorker.new(queue: @queue, promoter: promoter, transfer_log: @log, logger: null_logger,
                        regenerate: -> { @refreshes += 1 },
                        notify: ->(message, **opts) { @pushes << [message, opts] })
  end

  def file_record(library)
    @log.append('status' => 'ok', 'outcome' => 'tv', 'action' => 'link', 'message' => 'Linked', 'media_file' => '/dl/x.mkv',
                'destination' => library, 'torrent' => { 'name' => 'Show.S01E01', 'hash' => HASH })
  end

  it 'promotes the record for a queued hash, records it, notifies and refreshes the dashboard' do
    with_tmpdir do |dir|
      w = setup(dir)
      library = touch(File.join(@media, 'tv', 'Show.S01E01.mkv'), 'x')
      file_record(library)
      @queue.enqueue('promote', 'hash' => HASH.upcase)

      jobs = w.process!
      expect(jobs.count).to eq(1)
      expect(jobs.first.status).to include('state' => 'done', 'message' => "Promoted Show.S01E01.mkv to #{File.join(@nas, 'tv')}")
      expect(File.exist?(File.join(@nas, 'tv', 'Show.S01E01.mkv'))).to be true
      expect(File.exist?(library)).to be false

      record = @log.records.first
      expect(record).to include('status' => 'ok', 'outcome' => 'tv', 'action' => 'promote', 'job' => jobs.first.id,
                                'destination' => File.join(@nas, 'tv', 'Show.S01E01.mkv'))
      expect(record['torrent']).to eq('name' => 'Show.S01E01', 'hash' => HASH)
      expect(record['repro']).to end_with("transfers-worker.rb promote #{HASH}")
      expect(@pushes.map(&:first)).to eq(["Promoted Show.S01E01.mkv to #{File.join(@nas, 'tv')}"])
      expect(@pushes.first.last).to include(title: 'Promoted to NAS')
      expect(@refreshes).to eq(1)
      expect(@queue.pending).to be_empty
    end
  end

  it 'promotes a path directly and says when the download copy is kept' do
    with_tmpdir do |dir|
      w = setup(dir)
      download = touch(File.join(dir, 'dl', 'Film.mkv'), 'x')
      library = File.join(@media, 'movies', 'Film.mkv')
      FileUtils.mkdir_p(File.dirname(library))
      File.link(download, library)
      job = @queue.take(@queue.enqueue('promote', 'path' => library, 'keep_link' => true))
      w.run(job)
      expect(job.status['message']).to eq("Promoted Film.mkv to #{File.join(@nas, 'movies')}; download copy kept for seeding")
      expect(File.symlink?(library)).to be true
      expect(@log.records.first).to include('outcome' => 'file', 'action' => 'promote', 'torrent' => { 'name' => 'Film.mkv' })
      expect(@log.records.first['repro']).to end_with("promote #{library} --keep-link")
    end
  end

  it 'records a failure, logs it in the job and pushes a high-priority notification' do
    with_tmpdir do |dir|
      w = setup(dir, mounted: false)
      library = touch(File.join(@media, 'tv', 'Show.S01E01.mkv'), 'x')
      file_record(library)
      job = @queue.take(@queue.enqueue('promote', 'hash' => HASH))
      w.run(job)

      expect(job.status).to include('state' => 'failed', 'message' => a_string_matching(/NotMounted/))
      expect(job.log_tail).to include('FAILED: Promoter::NotMounted')
      expect(File.exist?(library)).to be true
      record = @log.records.first
      expect(record).to include('status' => 'error', 'outcome' => 'tv', 'action' => 'promote', 'job' => job.id)
      expect(record['error']['class']).to eq('Promoter::NotMounted')
      expect(@pushes.first.last).to include(title: 'Promote failed', priority: :high)
      expect(@refreshes).to eq(1)
    end
  end

  it 'fails a job for an unknown hash or action without raising' do
    with_tmpdir do |dir|
      w = setup(dir)
      w.run(@queue.take(@queue.enqueue('promote', 'hash' => 'd' * 40)))
      w.run(@queue.take(@queue.enqueue('shred', 'hash' => HASH)))
      expect(@queue.jobs.map { |j| j.status['message'] }).to contain_exactly(a_string_matching(/Unknown action "shred"/),
                                                                             a_string_matching(/No transfer record for hash/))
      expect(@log.records.map { |r| r['status'] }).to eq(%w[error error])
    end
  end

  it 'keeps going when the dashboard refresh fails' do
    with_tmpdir do |dir|
      w = setup(dir)
      w.instance_variable_set(:@regenerate, -> { raise 'no apache' })
      job = @queue.take(@queue.enqueue('promote', 'hash' => 'd' * 40))
      expect { w.run(job) }.not_to raise_error
      expect(job.log_tail).to include('Dashboard refresh failed: RuntimeError: no apache')
    end
  end
end
