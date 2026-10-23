# frozen_string_literal: true

require 'rspec'
require 'json'
require 'open3'
require_relative 'spec_helper_transfers'

# The CGI is run as a process, the way Apache runs it.
describe 'transfers-api.rb (CGI)' do
  include TransferSpecHelpers

  CGI_PATH = File.expand_path('../../web/cgi/transfers-api.rb', __dir__)

  def call(queue, body: nil, method: 'POST', requested_with: 'transfers')
    env = { 'TRANSFERS_QUEUE' => queue, 'REQUEST_METHOD' => method, 'REMOTE_ADDR' => '10.0.0.2' }
    env['HTTP_X_REQUESTED_WITH'] = requested_with if requested_with
    env['CONTENT_LENGTH'] = body.bytesize.to_s if body
    out, _err, _st = Open3.capture3(env, RbConfig.ruby, CGI_PATH, stdin_data: body.to_s)
    headers, json = out.split("\r\n\r\n", 2)
    [headers[/Status: (\d+)/, 1].to_i, JSON.parse(json)]
  end

  it 'queues a well-formed promote request' do
    with_tmpdir do |dir|
      queue = File.join(dir, 'queue')
      FileUtils.mkdir_p(queue)
      status, body = call(queue, body: JSON.generate('action' => 'promote', 'hash' => 'A' * 40))
      expect(status).to eq(202)
      expect(body).to include('action' => 'promote', 'hash' => 'a' * 40)
      files = Dir.glob(File.join(queue, '*.json'))
      expect(files.count).to eq(1)
      job = JSON.parse(File.read(files.first))
      expect(job).to include('action' => 'promote', 'hash' => 'a' * 40, 'via' => 'dashboard', 'from' => '10.0.0.2')
      expect(job).not_to have_key('keep_link') # only set when asked for
    end
  end

  it 'rejects anything but a POST carrying the X-Requested-With header' do
    with_tmpdir do |dir|
      expect(call(dir, method: 'GET').first).to eq(405)
      expect(call(dir, body: '{}', requested_with: nil).first).to eq(403)
      expect(call(dir, body: '{}', requested_with: 'XMLHttpRequest').first).to eq(403)
      expect(Dir.glob(File.join(dir, '*'))).to be_empty
    end
  end

  it 'validates the body' do
    with_tmpdir do |dir|
      expect(call(dir, body: '').first).to eq(400)
      expect(call(dir, body: 'nope')).to eq([400, { 'error' => 'body is not JSON' }])
      expect(call(dir, body: JSON.generate('action' => 'delete', 'hash' => 'a' * 40)).last['error']).to match(/action must be/)
      expect(call(dir, body: JSON.generate('action' => 'promote', 'hash' => '/etc/passwd')).last['error']).to match(/40 hex/)
      expect(call(dir, body: 'x' * 5000).first).to eq(400)
      expect(Dir.glob(File.join(dir, '*'))).to be_empty
    end
  end

  it 'accepts the remove and unlink actions with their options' do
    with_tmpdir do |dir|
      status, body = call(dir, body: JSON.generate('action' => 'remove_torrent', 'hash' => 'B' * 40, 'keep_library' => false))
      expect(status).to eq(202)
      expect(body).to include('action' => 'remove_torrent', 'hash' => 'b' * 40)
      status, = call(dir, body: JSON.generate('action' => 'unlink_library', 'hash' => 'c' * 40))
      expect(status).to eq(202)
      jobs = Dir.glob(File.join(dir, '*.json')).sort.map { |f| JSON.parse(File.read(f)) }
      expect(jobs.map { |j| j['action'] }).to contain_exactly('remove_torrent', 'unlink_library')
      expect(jobs.find { |j| j['action'] == 'remove_torrent' }).to include('keep_library' => false)
      expect(jobs.find { |j| j['action'] == 'unlink_library' }).not_to have_key('keep_library')
    end
  end

  it 'accepts a library path only where the action allows it, and only inside the library' do
    with_tmpdir do |dir|
      env_root = '/Users/theater/Media'
      status, body = call(dir, body: JSON.generate('action' => 'promote', 'path' => "#{env_root}/tv/X.mkv"))
      expect(status).to eq(202)
      expect(body).to include('path' => "#{env_root}/tv/X.mkv")
      expect(JSON.parse(File.read(Dir.glob(File.join(dir, '*.json')).first))).to include('path' => "#{env_root}/tv/X.mkv")
      expect(call(dir, body: JSON.generate('action' => 'unlink_library', 'path' => '/etc/passwd')).last['error']).to match(/must be under/)
      expect(call(dir, body: JSON.generate('action' => 'unlink_library', 'path' => "#{env_root}/tv/../../x")).last['error']).to match(/must be under/)
      # remove_torrent takes a hash only: a path falls through to hash validation
      expect(call(dir, body: JSON.generate('action' => 'remove_torrent', 'path' => "#{env_root}/tv/X.mkv")).last['error']).to match(/40 hex/)
      expect(Dir.glob(File.join(dir, '*.json')).count).to eq(1)
    end
  end

  it 'explains when the queue directory is not writable' do
    with_tmpdir do |dir|
      status, body = call(File.join(dir, 'missing'), body: JSON.generate('action' => 'promote', 'hash' => 'a' * 40))
      expect(status).to eq(500)
      expect(body['error']).to include('chmod 1777')
    end
  end
end
