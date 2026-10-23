# frozen_string_literal: true

require 'feed_cache'
require 'rspec'
require 'webrick'
require 'webrick/https'

describe 'FeedCache' do
  RSS_BODY = <<~XML
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>t</title><link>http://x</link><description>d</description>
    <item><title>Show.S01E01</title><link>http://x/1</link></item>
    <item><title>Show.S01E02</title><link>http://x/2</link></item>
    </channel></rss>
  XML

  # Serve the feed over HTTP, the way the real feeds are fetched, and record
  # each request so the specs can see the query and the request count.
  around do |example|
    @requests = []
    started = Queue.new
    @server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1', StartCallback: -> { started << true },
                                      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc('/feed') do |req, res|
      @requests << req.query_string
      res['Content-Type'] = 'application/rss+xml'
      res.body = RSS_BODY
    end
    thread = Thread.new { @server.start }
    started.pop # A shutdown before start would leave the server running.
    begin
      example.run
    ensure
      @server.shutdown
      thread.join
    end
  end

  def feed_url
    "http://127.0.0.1:#{@server.config[:Port]}/feed?id=7"
  end

  def cache
    c = FeedCache.new([{ 'name' => 'tv', 'url' => feed_url, 'passkey_file' => 'passkey' }])
    allow(c).to receive(:first_line_from_file).and_return('secret')
    c
  end

  it 'loads feeds on access' do
    expect { cache.items_for_feed('tv') }.to output(/Loaded 2 items for tv/).to_stdout
    expect(cache.items_for_feed('tv').map(&:title)).to eq(%w[Show.S01E01 Show.S01E02])
  end

  it 'memoizes loaded feeds' do
    c = cache
    expect do
      c.items_for_feed('tv')
      c.items_for_feed('tv')
    end.to output.to_stdout
    expect(@requests.count).to eq(1)
  end

  it 'attaches passkey' do
    expect { cache.items_for_feed('tv') }.to output.to_stdout
    expect(@requests.first).to eq('id=7&passkey=secret')
  end

  it 'refuses a server whose certificate it cannot verify' do
    started = Queue.new
    https = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1', StartCallback: -> { started << true },
                                    SSLEnable: true, SSLCertName: [%w[CN localhost]],
                                    Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    https.mount_proc('/feed') { |_, res| res.body = RSS_BODY }
    thread = Thread.new { https.start }
    started.pop
    begin
      c = FeedCache.new([{ 'name' => 'tv', 'url' => "https://localhost:#{https.config[:Port]}/feed?id=7", 'passkey_file' => 'x' }])
      allow(c).to receive(:first_line_from_file).and_return('secret')
      expect do
        expect { c.items_for_feed('tv') }.to raise_error(SystemExit)
      end.to output(/certificate verify failed/).to_stdout
    ensure
      https.shutdown
      thread.join
    end
  end

  it 'returns no items for an unknown feed' do
    expect(cache.items_for_feed('movies')).to eq([])
    expect(@requests).to be_empty
  end
end
