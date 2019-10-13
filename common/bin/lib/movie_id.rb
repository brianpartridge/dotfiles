# frozen_string_literal: true

# Model to identify movies
class MovieID
  attr_reader :title, :year
  def initialize(title, year)
    @title = title
    @year = year.to_i
  end

  def to_s
    "#{@title} (#{@year})"
  end

  def self.from_s(s)
    match_data = s.match(/(?<title>.+) \((?<year>(19|20)\d{2})\)/)
    return nil unless match_data

    MovieID.new(match_data['title'], match_data['year'])
  end

  def self.from_release(name)
    sanitized_name = name.gsub(/h.264/i, '').gsub(/720p/i, '').gsub(/1080p/i, '')
    match_data = sanitized_name.match(/(?<title>.+)[\._ \-](?<year>(19|20)\d{2})[\._ \-]/)
    return nil unless match_data

    sanitized_title = match_data['title'].gsub(/[\._ ]/i, ' ')
    MovieID.new(sanitized_title, match_data['year'])
  end

  def ==(movie)
    return false unless @year == movie.year

    @title.downcase == movie.title.downcase
  end

  def eql?(movie)
    self == movie
  end

  def hash
    to_s.hash
  end
end
