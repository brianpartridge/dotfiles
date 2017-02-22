require 'episode_id'

class Media
    def from_path(path)
        @path = path
    end

    def name
        if File.directory? @path
            File.basename @path
        else
            File.basename(@path, File.extname(@path))
        end
    end

    def self.tv?(name)
        !(EpisodeID.from_release(name).nil?)
    end

    def self.movie?(name)
        !!(name =~ /.+[\._ \-](19|20)\d{2}/)
    end
end
