# frozen_string_literal: true

MAX_LEN = 140

class String
  def truncate(max)
    length > max ? (self[0...max]).to_s : self
  end
end

def tweet(message)
  # dont post to twitter because i dont use it anymore  
  puts "Not tweeting: #{message.truncate(MAX_LEN)}"
  # return if `which t`.empty?
  #`t update "#{message.truncate(MAX_LEN)}"`
end
