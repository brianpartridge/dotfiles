# frozen_string_literal: true

require_relative 'notify'

MAX_LEN = 140

class String
  def truncate(max)
    length > max ? (self[0...max]).to_s : self
  end
end

# Legacy notification shim. Messages look like "LEVEL:text"; the level picks
# the notification title and priority. Twitter is long gone; this now goes to
# Pushover via Notify. START messages are sent at the lowest priority so they
# appear in the Pushover app's history without buzzing your phone.
TWEET_LEVELS = {
  'START' => [:lowest, 'Started'],
  'SUCCESS' => [:normal, 'Success'],
  'WARNING' => [:normal, 'Warning'],
  'FAILURE' => [:high, 'Failure']
}.freeze

def tweet(message)
  level, text = message.split(':', 2)
  priority, title = TWEET_LEVELS.fetch(level, [:normal, nil])
  text = message if text.nil?
  puts "Notifying: #{message.truncate(MAX_LEN)}"
  Notify.push(text.strip, title: title, priority: priority)
end
