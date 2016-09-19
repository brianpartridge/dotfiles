require 'episode_id'
require 'rspec'

describe 'EpisodeID' do
  before do
    @oneone = EpisodeID.new(1, 1)
    @onetwo = EpisodeID.new(1, 2)
    @twoone = EpisodeID.new('2', '1')
  end

  describe 'initialize' do
    it 'stores attributes' do
      expect(@onetwo.season).to eq(1)
      expect(@onetwo.episode).to eq(2)
    end

    it 'handles string input' do
      expect(@twoone.season).to eq(2)
      expect(@twoone.episode).to eq(1)
    end
  end

  describe 'compares' do
    it 'handles eqity' do
      expect(@oneone).to eq(@oneone)
      expect(@onetwo).to eq(@onetwo)
      expect(@twoone).to eq(@twoone)
    end

    it 'handles relative ordering' do
      expect(@oneone).to be < @onetwo
      expect(@oneone).to be < @twoone
      expect(@onetwo).to be < @twoone

      expect(@twoone).to be > @oneone
      expect(@twoone).to be > @onetwo
      expect(@onetwo).to be > @oneone
    end
  end

  describe 'to_s' do
    it 'formats' do
      expect(@oneone.to_s).to eq('S01E01')
      expect(@onetwo.to_s).to eq('S01E02')
      expect(@twoone.to_s).to eq('S02E01')
    end
  end
end

