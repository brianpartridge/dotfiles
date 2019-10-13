# frozen_string_literal: true

# Model to simplify comparison of S#E#-based episodes
class EpisodeID
  attr_reader :season, :episode, :is_miniseries
  def initialize(season, episode, is_miniseries = false)
    @season = season.to_i
    @episode = episode.to_i
    @is_miniseries = is_miniseries
  end

  def to_s
    return format('Part%02i', @episode) if @is_miniseries

    format('S%02iE%02i', @season, @episode)
  end

  def self.from_s(s)
    match_data = s.match(/^Part(?<episode>\d+)$/)
    return EpisodeID.new(1, match_data['episode'], true) if match_data

    match_data = s.match(/^S(?<season>\d+)E(?<episode>\d+)$/)
    if match_data
      return EpisodeID.new(match_data['season'], match_data['episode'])
    end

    nil
  end

  def self.from_release(name)
    sanitized_name = name.gsub(/h.264/i, '').gsub(/720p/i, '').gsub(/1080p/i, '')

    match_data = sanitized_name.match(/^(?<series>.+)[\._ \-][Pp]art(?<episode>\d{2})[\._ \-]/)
    return EpisodeID.new(1, match_data['episode'], true) if match_data

    match_data = sanitized_name.match(/^(?<series>.+)[\._ \-][Ss]?(?<season>\d+)[\._ \-]?[EeXx](?<episode>\d{2})[\._ \-]/)
    if match_data
      return EpisodeID.new(match_data['season'], match_data['episode'])
    end

    nil
  end

  def <(ep)
    (self <=> ep) == -1
  end

  def >(ep)
    (self <=> ep) == 1
  end

  def ==(ep)
    (self <=> ep) == 0
  end

  def eql?(ep)
    self == ep
  end

  def <=>(ep)
    if @season < ep.season
      -1
    elsif @season > ep.season
      1
    elsif @episode < ep.episode
      -1
    elsif @episode > ep.episode
      1
    else
      0
    end
  end

  def hash
    to_s.hash
  end
end
