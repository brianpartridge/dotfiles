require 'media_parser'
require 'rspec'

describe 'Media' do
    it 'identifies tv by name' do
        Media.tv?('Show.Title.S01E02.Episode.Title.720p.HDTV.x264-GROUP.mkv').should be_truthy
        Media.tv?('Movie.Title.2016.720p.BluRay.x264-GROUP').should be_falsy
    end

    it 'identifies movies by name' do
        Media.movie?('Movie.Title.2016.720p.BluRay.x264-GROUP').should be_truthy
        Media.movie?('Show.Title.S01E02.Episode.Title.720p.HDTV.x264-GROUP.mkv').should be_falsy
    end

    it 'parses names from directory paths' do
    end

    it 'parses names from file paths' do
    end
end

