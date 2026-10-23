# frozen_string_literal: true

require 'rspec'
require 'job_queue'
require_relative 'spec_helper_transfers'

describe JobQueue do
  include TransferSpecHelpers

  def queue_in(dir)
    JobQueue.new(queue_dir: File.join(dir, 'queue'), jobs_dir: File.join(dir, 'jobs'))
  end

  it 'enqueues a request as a JSON file and lists it oldest first' do
    with_tmpdir do |dir|
      q = queue_in(dir)
      first = q.enqueue('promote', 'hash' => 'a' * 40)
      second = q.enqueue('promote', 'path' => '/x')
      expect(q.pending).to eq([first, second].sort)
      expect(JSON.parse(File.read(first))).to include('action' => 'promote', 'hash' => 'a' * 40, 'requested_at' => a_kind_of(String))
      expect(Dir.glob(File.join(dir, 'queue', '*.tmp'))).to be_empty
    end
  end

  it 'is empty before the queue directory exists' do
    with_tmpdir do |dir|
      expect(queue_in(dir).pending).to eq([])
      expect(queue_in(dir).jobs).to eq([])
    end
  end

  it 'moves a request into its own job directory and tracks status and log' do
    with_tmpdir do |dir|
      q = queue_in(dir)
      file = q.enqueue('promote', 'hash' => 'abc123' + 'f' * 34)
      job = q.take(file)
      expect(q.pending).to be_empty
      expect(job.id).to match(/\A\d{8}-\d{6}-promote-abc123f/)
      expect(job.request).to include('action' => 'promote')
      expect(job.status).to be_nil

      job.start!('promote', 'abc123')
      job.log 'hello'
      job.log 'world'
      expect(job.status).to include('state' => 'running', 'action' => 'promote', 'subject' => 'abc123')
      job.finish!('done', 'all good')
      expect(job.status).to include('state' => 'done', 'message' => 'all good', 'started_at' => a_kind_of(String), 'finished_at' => a_kind_of(String))
      expect(job.log_tail).to match(/\d\d:\d\d:\d\d hello\n\d\d:\d\d:\d\d world\n/)
      expect(job.log_tail(1)).to end_with("world\n")

      expect(q.jobs.map(&:id)).to eq([job.id])
    end
  end

  it 'parks a request that is not JSON in rejected/' do
    with_tmpdir do |dir|
      q = queue_in(dir)
      bad = touch(File.join(dir, 'queue', '1-bad.json'), '{not json')
      expect(q.take(bad)).to be_nil
      expect(File.exist?(bad)).to be false
      expect(File.exist?(File.join(dir, 'queue', 'rejected', '1-bad.json'))).to be true
      expect(q.jobs).to be_empty
    end
  end

  it 'lists jobs newest first and limits them' do
    with_tmpdir do |dir|
      q = queue_in(dir)
      %w[20260101-000000-a 20260102-000000-b 20260103-000000-c].each { |id| FileUtils.mkdir_p(File.join(dir, 'jobs', id)) }
      expect(q.jobs(limit: 2).map(&:id)).to eq(%w[20260103-000000-c 20260102-000000-b])
    end
  end
end
