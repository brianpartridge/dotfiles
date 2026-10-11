# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# Push notifications via Pushover (https://pushover.net).
#
# Credentials live in a JSON file, by default ~/Dropbox/conf/pushover.json:
#
#   { "token": "<application API token>", "user": "<user key>" }
#
# Optional keys: "device" (only notify one device), "sound".
#
# Notify never raises. A failed or unconfigured notification is written to
# stderr and reported through the return value so that a notification problem
# can never derail the work that was being notified about.
module Notify
  API_URL = URI('https://api.pushover.net/1/messages.json')
  DEFAULT_CONFIG = '~/Dropbox/conf/pushover.json'
  PRIORITY = { lowest: -2, low: -1, normal: 0, high: 1, emergency: 2 }.freeze
  MESSAGE_LIMIT = 1024
  TITLE_LIMIT = 250

  class << self
    # Override the config file location (also honours $PUSHOVER_CONFIG).
    attr_writer :config_path
    # Override how the request is sent; a callable taking the form params and
    # returning something that responds to #code and #body. Used by specs.
    attr_writer :transport

    def config_path
      @config_path || ENV['PUSHOVER_CONFIG'] || DEFAULT_CONFIG
    end

    def config
      path = File.expand_path(config_path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      log "Invalid Pushover config #{path}: #{e.message}"
      nil
    end

    def configured?
      c = config
      !c.nil? && !c['token'].to_s.empty? && !c['user'].to_s.empty?
    end

    # Send a notification. Returns true if Pushover accepted it, false otherwise.
    #
    # priority: one of the PRIORITY keys or a raw integer. :lowest shows up in
    # the Pushover app without alerting; :high bypasses quiet hours.
    def push(message, title: nil, priority: :normal, url: nil, url_title: nil)
      c = config
      if c.nil? || c['token'].to_s.empty? || c['user'].to_s.empty?
        log "Not sending (no Pushover config at #{config_path}): #{[title, message].compact.join(' - ')}"
        return false
      end

      params = {
        'token' => c['token'],
        'user' => c['user'],
        'message' => message.to_s[0, MESSAGE_LIMIT],
        'priority' => PRIORITY.fetch(priority, priority).to_i
      }
      params['title'] = title.to_s[0, TITLE_LIMIT] if title
      params['device'] = c['device'] if c['device']
      params['sound'] = c['sound'] if c['sound']
      params['url'] = url if url
      params['url_title'] = url_title if url_title
      if params['priority'] >= PRIORITY[:emergency]
        params['retry'] = 60
        params['expire'] = 3600
      end

      response = transport.call(params)
      ok = response.code.to_i == 200
      log "Pushover rejected notification (HTTP #{response.code}): #{response.body}" unless ok
      ok
    rescue StandardError => e
      log "Pushover notification failed: #{e.class}: #{e.message}"
      false
    end

    def transport
      @transport || method(:http_post)
    end

    private

    def http_post(params)
      http = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15
      request = Net::HTTP::Post.new(API_URL.path)
      request.set_form_data(params)
      http.request(request)
    end

    def log(message)
      $stderr.puts "[notify] #{message}"
    end
  end
end
