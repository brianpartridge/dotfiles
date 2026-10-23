# frozen_string_literal: true

require 'rspec'
require 'transfer_log'
require_relative 'spec_helper_transfers'

describe TransferLog do
  around { |example| with_tmpdir { |dir| @path = File.join(dir, 'nested', 'transfers.jsonl'); example.run } }

  subject(:log) { TransferLog.new(@path) }

  it 'returns no records before anything is written' do
    expect(log.records).to eq([])
  end

  it 'appends records with a timestamp and string keys, creating directories' do
    written = log.append(status: 'ok', torrent: { name: 'foo' })
    expect(written['ts']).to match(/\d{4}-\d{2}-\d{2}T/)
    expect(written['torrent']).to eq('name' => 'foo')
    expect(File.read(@path).lines.count).to eq(1)
  end

  it 'reads newest first and honours the limit' do
    3.times { |i| log.append('status' => 'ok', 'n' => i) }
    expect(log.records.map { |r| r['n'] }).to eq([2, 1, 0])
    expect(log.records(limit: 2).map { |r| r['n'] }).to eq([2, 1])
  end

  it 'skips malformed lines' do
    log.append('n' => 1)
    File.open(@path, 'a') { |f| f.puts('{"partial":') }
    log.append('n' => 2)
    expect(log.records.map { |r| r['n'] }).to eq([2, 1])
  end

  it 'parses record times' do
    expect(TransferLog.time_of('ts' => '2026-01-02T03:04:05Z')).to eq(Time.utc(2026, 1, 2, 3, 4, 5))
    expect(TransferLog.time_of('ts' => 'garbage')).to be_nil
    expect(TransferLog.time_of({})).to be_nil
  end
end
