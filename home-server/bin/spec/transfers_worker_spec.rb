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

  describe 'remove_torrent and unlink_library' do
    def with_remover(w)
      @remover = instance_double(MediaRemover)
      w.instance_variable_set(:@remover, @remover)
    end

    it 'removes a torrent, records what was freed and kept, and notifies' do
      with_tmpdir do |dir|
        w = setup(dir)
        with_remover(w)
        file_record(File.join(@media, 'tv', 'Show.S01E01.mkv'))
        expect(@remover).to receive(:remove_torrent).with(HASH, keep_library: true)
                                                   .and_return('torrent' => 'Show.S01E01', 'hash' => HASH, 'freed' => 2_500_000_000,
                                                               'kept' => [File.join(@media, 'tv', 'Show.S01E01.mkv')], 'removed_library' => [], 'ratio' => 1.8)
        job = @queue.take(@queue.enqueue('remove_torrent', 'hash' => HASH))
        w.run(job)
        expect(job.status).to include('state' => 'done', 'message' => 'Removed Show.S01E01 from Transmission (ratio 1.8), freed 2.5 GB; 1 library file(s) kept')
        record = @log.records.first
        expect(record).to include('status' => 'ok', 'outcome' => 'tv', 'action' => 'remove', 'freed' => 2_500_000_000, 'job' => job.id)
        expect(record['torrent']).to eq('name' => 'Show.S01E01', 'hash' => HASH)
        expect(record['repro']).to end_with("remove_torrent #{HASH}")
        expect(@pushes.first.last).to include(title: 'Torrent removed')
        expect(@refreshes).to eq(1)
      end
    end

    it 'passes keep_library false through and says the library files went' do
      with_tmpdir do |dir|
        w = setup(dir)
        with_remover(w)
        expect(@remover).to receive(:remove_torrent).with(HASH, keep_library: false)
                                                   .and_return('torrent' => 'X', 'hash' => HASH, 'freed' => 10, 'kept' => [], 'removed_library' => ['/m/tv/x.mkv'], 'ratio' => 0.5)
        job = @queue.take(@queue.enqueue('remove_torrent', 'hash' => HASH, 'keep_library' => false))
        w.run(job)
        expect(job.status['message']).to end_with('1 library file(s) removed')
        expect(@log.records.first['repro']).to end_with(' --remove-library')
        expect(@log.records.first['outcome']).to eq('unknown_media') # no transfer record for it
      end
    end

    it 'unlinks library entries by hash or path' do
      with_tmpdir do |dir|
        w = setup(dir)
        with_remover(w)
        expect(@remover).to receive(:unlink_library).with(hash: nil, path: '/m/tv/a.mkv').and_return('removed_library' => ['/m/tv/a.mkv'])
        job = @queue.take(@queue.enqueue('unlink_library', 'path' => '/m/tv/a.mkv'))
        w.run(job)
        expect(job.status).to include('state' => 'done', 'message' => 'Removed a.mkv from the local library')
        expect(@log.records.first).to include('action' => 'unlink', 'outcome' => 'file', 'torrent' => { 'name' => 'a.mkv' })
        expect(@pushes.first.last).to include(title: 'Removed from library')
      end
    end

    it 'turns a remover error into a failed job with a high-priority push' do
      with_tmpdir do |dir|
        w = setup(dir)
        with_remover(w)
        allow(@remover).to receive(:remove_torrent).and_raise(RuntimeError, 'still downloading (30%)')
        job = @queue.take(@queue.enqueue('remove_torrent', 'hash' => HASH))
        w.run(job)
        expect(job.status).to include('state' => 'failed', 'message' => 'RuntimeError: still downloading (30%)')
        expect(@log.records.first).to include('status' => 'error', 'action' => 'remove_torrent')
        expect(@pushes.first.last).to include(title: 'Remove_torrent failed', priority: :high)
      end
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

  describe 'rerun_finish' do
    def rerun_worker(dir, torrents: [], rpc_error: nil, &finisher)
      @queue = JobQueue.new(queue_dir: File.join(dir, 'queue'), jobs_dir: File.join(dir, 'jobs'))
      @log = TransferLog.new(File.join(dir, 'transfers.jsonl'))
      @pushes = []
      @refreshes = 0
      @envs = []
      rpc = instance_double(TransmissionRPC)
      if rpc_error
        allow(rpc).to receive(:torrents).and_raise(TransmissionRPC::Error, rpc_error)
      else
        allow(rpc).to receive(:torrents).and_return(torrents)
      end
      promoter = Promoter.new(nas_root: File.join(dir, 'nas'), media_root: File.join(dir, 'Media'), logger: null_logger)
      TransfersWorker.new(queue: @queue, promoter: promoter, rpc: rpc, transfer_log: @log, logger: null_logger,
                          regenerate: -> { @refreshes += 1 },
                          notify: ->(message, **opts) { @pushes << [message, opts] },
                          finisher: lambda { |env|
                            @envs << env
                            finisher.call(env)
                          })
    end

    def complete_torrent(percent: 1.0)
      { 'id' => 7, 'name' => 'Show.S01E01', 'hashString' => HASH, 'downloadDir' => '/dl/complete', 'percentDone' => percent }
    end

    # What torrent-finished.rb writes to the transfer log.
    def finish_record(status, message)
      @log.append('status' => status, 'outcome' => status == 'ok' ? 'tv' : 'error', 'action' => 'link', 'message' => message,
                  'torrent' => { 'name' => 'Show.S01E01', 'hash' => HASH, 'directory' => '/dl/complete' })
    end

    it 'runs the done-script with the Transmission environment and reports its outcome' do
      with_tmpdir do |dir|
        w = rerun_worker(dir, torrents: [complete_torrent]) do |_env|
          finish_record('ok', 'Linked Show.S01E01.mkv')
          ["STARTING\nFINISHED: ok\n", true]
        end
        @queue.enqueue('rerun_finish', 'hash' => HASH.upcase)

        job = w.process!.first
        expect(@envs).to eq([{ 'TR_TORRENT_NAME' => 'Show.S01E01', 'TR_TORRENT_DIR' => '/dl/complete',
                               'TR_TORRENT_HASH' => HASH, 'TR_TORRENT_ID' => '7' }])
        expect(job.status).to include('state' => 'done', 'message' => 'Re-ran torrent-finished.rb: Linked Show.S01E01.mkv')
        expect(job.log_tail).to include('FINISHED: ok')
        expect(@log.records.count).to eq(1) # the script's own record only
        expect(@pushes).to be_empty # the script sends its own notification
        expect(@refreshes).to eq(1)
      end
    end

    it 'uses the transfer record when Transmission no longer has the torrent, or is unreachable' do
      [{ torrents: [] }, { rpc_error: 'connection refused' }].each do |transmission|
        with_tmpdir do |dir|
          w = rerun_worker(dir, **transmission) { |_env| ['', true] }
          finish_record('error', 'NoMethodError')
          @queue.enqueue('rerun_finish', 'hash' => HASH)

          job = w.process!.first
          expect(job.status).to include('state' => 'done')
          expect(@envs.first).to include('TR_TORRENT_NAME' => 'Show.S01E01', 'TR_TORRENT_DIR' => '/dl/complete', 'TR_TORRENT_ID' => '')
          expect(job.log_tail).to match(/does not know this torrent|unreachable/)
        end
      end
    end

    it 'leaves the failure record and notification to the done-script when it fails again' do
      with_tmpdir do |dir|
        w = rerun_worker(dir, torrents: [complete_torrent]) do |_env|
          finish_record('error', 'Destination directory is missing')
          ['ERROR', false]
        end
        @queue.enqueue('rerun_finish', 'hash' => HASH)

        job = w.process!.first
        expect(job.status).to include('state' => 'failed',
                                      'message' => 'TransfersWorker::FinishScriptFailed: torrent-finished.rb failed: Destination directory is missing')
        expect(@log.records.count).to eq(1)
        expect(@pushes).to be_empty
      end
    end

    it 'refuses a torrent that is still downloading or that it cannot find' do
      with_tmpdir do |dir|
        w = rerun_worker(dir, torrents: [complete_torrent(percent: 0.4)]) { |_env| raise 'must not run' }
        @queue.enqueue('rerun_finish', 'hash' => HASH)
        @queue.enqueue('rerun_finish', 'hash' => 'e' * 40)

        jobs = w.process!
        expect(jobs.map { |j| j.status['message'] }).to contain_exactly(
          'RuntimeError: Show.S01E01 is still downloading (40%)',
          "RuntimeError: Cannot find torrent #{'e' * 40} in Transmission or the transfer log"
        )
        expect(@envs).to be_empty
        expect(@log.records.map { |r| r['action'] }).to eq(%w[rerun_finish rerun_finish])
        expect(@pushes.map { |p| p.last[:title] }).to eq(['Rerun_finish failed', 'Rerun_finish failed'])
      end
    end
  end
end
