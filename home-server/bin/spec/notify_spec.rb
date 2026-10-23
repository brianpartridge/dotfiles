# frozen_string_literal: true

require 'rspec'
require 'notify'
require_relative 'spec_helper_transfers'

describe Notify do
  around do |example|
    with_tmpdir do |dir|
      @conf = File.join(dir, 'pushover.json')
      Notify.config_path = @conf
      @sent = []
      Notify.transport = lambda { |params|
        @sent << params
        FakeResponse.new('200', '{"status":1}')
      }
      example.run
    end
  ensure
    Notify.config_path = nil
    Notify.transport = nil
  end

  it 'is unconfigured without a config file' do
    expect(Notify.configured?).to be false
  end

  it 'does not send and returns false when unconfigured' do
    expect { expect(Notify.push('hi')).to be false }.to output(/no Pushover config/).to_stderr
    expect(@sent).to be_empty
  end

  context 'configured' do
    before { File.write(@conf, '{"token":"t","user":"u","sound":"pushover"}') }

    it 'posts token, user, message, title and mapped priority' do
      expect(Notify.push('body', title: 'Title', priority: :high)).to be true
      expect(@sent.last).to include('token' => 't', 'user' => 'u', 'message' => 'body',
                                    'title' => 'Title', 'priority' => 1, 'sound' => 'pushover')
    end

    it 'accepts raw integer priorities and truncates long messages' do
      Notify.push('x' * 2000, priority: -2)
      expect(@sent.last['priority']).to eq(-2)
      expect(@sent.last['message'].length).to eq(Notify::MESSAGE_LIMIT)
    end

    it 'returns false on a rejected request' do
      Notify.transport = ->(_) { FakeResponse.new('400', '{"errors":["bad"]}') }
      expect { expect(Notify.push('hi')).to be false }.to output(/rejected.*400/).to_stderr
    end

    it 'returns false, never raises, when the transport blows up' do
      Notify.transport = ->(_) { raise Errno::ECONNREFUSED }
      expect { expect(Notify.push('hi')).to be false }.to output(/failed/).to_stderr
    end

    it 'treats invalid JSON config as unconfigured' do
      File.write(@conf, '{not json')
      expect { expect(Notify.configured?).to be false }.to output(/Invalid/).to_stderr
    end
  end
end
