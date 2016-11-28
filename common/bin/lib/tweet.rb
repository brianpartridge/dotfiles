MAX_LEN = 140

class String
    def truncate(max)
        length > max ? "#{self[0...max]}" : self
    end
end

def tweet(message)
    return if `which t`.empty?
    `t update "#{message.truncate(MAX_LEN)}"`
end

