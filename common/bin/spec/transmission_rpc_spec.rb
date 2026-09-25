# frozen_string_literal: true

require 'rspec'
require 'transmission_rpc'
require_relative 'spec_helper_transfers'

describe TransmissionRPC do
  subject(:rpc) { TransmissionRPC.new(url: 'http://localhost:9091/transmission/rpc') }

  it 'negotiates the session id on 409 and returns arguments' do
    responses = [
      FakeResponse.new('409', '', TransmissionRPC::SESSION_HEADER => 'sess'),
      FakeResponse.new('200', '{"result":"success","arguments":{"torrents":[{"name":"a"}]}}', {})
    ]
    seen = []
    allow(rpc).to receive(:post) { |body| seen << body; responses.shift }
    expect(rpc.torrents).to eq([{ 'name' => 'a' }])
    expect(seen.count).to eq(2)
    expect(rpc.instance_variable_get(:@session_id)).to eq('sess')
  end

  it 'wraps connection failures in Error' do
    allow(rpc).to receive(:post).and_raise(Errno::ECONNREFUSED)
    expect { rpc.torrents }.to raise_error(TransmissionRPC::Error, /ECONNREFUSED/)
  end

  it 'raises on non-success results and bad HTTP codes' do
    allow(rpc).to receive(:post).and_return(FakeResponse.new('200', '{"result":"no such method"}', {}))
    expect { rpc.call('x') }.to raise_error(TransmissionRPC::Error, /no such method/)
    allow(rpc).to receive(:post).and_return(FakeResponse.new('500', '', {}))
    expect { rpc.call('x') }.to raise_error(TransmissionRPC::Error, /HTTP 500/)
  end

  it 'names statuses' do
    expect(TransmissionRPC.status_name(6)).to eq('seeding')
    expect(TransmissionRPC.status_name(42)).to eq('status 42')
  end

  it 'falls back to defaults without a config file' do
    with_tmpdir do |dir|
      expect(TransmissionRPC.from_config(File.join(dir, 'none.json')).uri.to_s).to eq(TransmissionRPC::DEFAULT_URL)
      File.write(File.join(dir, 'c.json'), '{"url":"http://box:9999/transmission/rpc","username":"u","password":"p"}')
      expect(TransmissionRPC.from_config(File.join(dir, 'c.json')).uri.host).to eq('box')
    end
  end
end
