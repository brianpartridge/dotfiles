# Model to simplify comparison of S#E#-based episodes
class EpisodeID 
  attr_reader :season, :episode
  def initialize(season, episode)
    @season = season.to_i
    @episode = episode.to_i
  end
 
  def to_s
    "S%02iE%02i" % [@season, @episode]
  end

  def self.from_s(s)
    match_data = s.match(/^S(?<season>\d+)E(?<episode>\d+)$/)
    return nil unless match_data
    EpisodeID.new(match_data['season'], match_data['episode'])
  end
 
  def self.from_release(name)
    sanitized_name = name.gsub(/h.264/i, '').gsub(/720p/i, '').gsub(/1080p/i, '')
    match_data = sanitized_name.match(/^(?<series>.+)[\._ \-][Ss]?(?<season>\d+)[\._ \-]?[EeXx](?<episode>\d{2})[\._ \-]/)
    return nil unless match_data
    EpisodeID.new(match_data['season'], match_data['episode'])
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
  
end

