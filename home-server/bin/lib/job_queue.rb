# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

# Dashboard-triggered work, as files.
#
# A request is a small JSON file dropped into the queue directory (by the CGI,
# running as Apache's user, or by transfers-worker.rb enqueue). launchd runs
# the worker whenever that directory is non-empty. The worker moves each
# request into its own job directory under JOBS_DIR, where it keeps
# request.json, status.json and log.txt; the dashboard reads those.
class JobQueue
  def initialize(queue_dir:, jobs_dir:)
    @queue_dir = queue_dir
    @jobs_dir = jobs_dir
  end

  attr_reader :queue_dir, :jobs_dir

  # Writes a request file. Returns its path.
  def enqueue(action, params = {})
    FileUtils.mkdir_p(@queue_dir)
    request = params.merge('action' => action, 'requested_at' => Time.now.iso8601)
    name = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}.json"
    path = File.join(@queue_dir, name)
    File.write("#{path}.tmp", JSON.pretty_generate(request))
    File.rename("#{path}.tmp", path)
    path
  end

  # Queued request files, oldest first.
  def pending
    return [] unless File.directory?(@queue_dir)

    Dir.glob(File.join(@queue_dir, '*.json')).sort
  end

  # Moves a request into a new job directory and returns the Job. A request
  # that is not valid JSON goes to the rejected folder instead (nil).
  def take(request_file)
    request = JSON.parse(File.read(request_file))
    subject = (request['hash'] || request['path'] || '').to_s
    id = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{request['action']}-#{File.basename(subject)[0, 12].gsub(/[^\w.-]/, '_')}"
    dir = File.join(@jobs_dir, id)
    dir = "#{dir}-#{SecureRandom.hex(2)}" if File.exist?(dir)
    FileUtils.mkdir_p(dir)
    File.rename(request_file, File.join(dir, 'request.json'))
    Job.new(dir)
  rescue JSON::ParserError
    rejected = File.join(@queue_dir, 'rejected')
    FileUtils.mkdir_p(rejected)
    File.rename(request_file, File.join(rejected, File.basename(request_file)))
    nil
  end

  # Known jobs, newest first.
  def jobs(limit: 20)
    return [] unless File.directory?(@jobs_dir)

    Dir.glob(File.join(@jobs_dir, '*')).select { |d| File.directory?(d) }.sort.reverse.first(limit).map { |d| Job.new(d) }
  end

  # One unit of work and its files.
  class Job
    attr_reader :dir

    def initialize(dir)
      @dir = dir
    end

    def id
      File.basename(@dir)
    end

    def request
      JSON.parse(File.read(File.join(@dir, 'request.json')))
    rescue StandardError
      {}
    end

    def status
      JSON.parse(File.read(File.join(@dir, 'status.json')))
    rescue StandardError
      nil
    end

    def log(message)
      File.open(File.join(@dir, 'log.txt'), 'a') { |f| f.puts "#{Time.now.strftime('%H:%M:%S')} #{message}" }
    end

    def log_tail(lines = 30)
      path = File.join(@dir, 'log.txt')
      return '' unless File.file?(path)

      File.readlines(path).last(lines).join
    end

    def start!(action, subject)
      write_status('state' => 'running', 'action' => action, 'subject' => subject, 'started_at' => Time.now.iso8601)
    end

    def finish!(state, message)
      write_status((status || {}).merge('state' => state, 'message' => message, 'finished_at' => Time.now.iso8601))
    end

    private

    def write_status(hash)
      path = File.join(@dir, 'status.json')
      File.write("#{path}.tmp", JSON.pretty_generate(hash))
      File.rename("#{path}.tmp", path)
    end
  end
end
