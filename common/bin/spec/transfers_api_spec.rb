# frozen_string_literal: true

require 'rspec'
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
      expect(JSON.parse(File.read(files.first))).to include('action' => 'promote', 'hash' => 'a' * 40, 'keep_link' => false,
                                                            'via' => 'dashboard', 'from' => '10.0.0.2')
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

  it 'explains when the queue directory is not writable' do
    with_tmpdir do |dir|
      status, body = call(File.join(dir, 'missing'), body: JSON.generate('action' => 'promote', 'hash' => 'a' * 40))
      expect(status).to eq(500)
      expect(body['error']).to include('chmod 1777')
    end
  end
end
