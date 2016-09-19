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

