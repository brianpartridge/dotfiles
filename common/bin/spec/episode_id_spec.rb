require 'episode_id'
require 'rspec'

describe 'EpisodeID' do
  def e11
    EpisodeID.new(1, 1)
  end

  def e12
    EpisodeID.new(1, 2)
  end

  def e21
    EpisodeID.new('2', '1')
  end

  describe 'initialize' do
    it 'stores attributes' do
      expect(e12.season).to eq(1)
      expect(e12.episode).to eq(2)
    end

    it 'handles string input' do
      expect(e21.season).to eq(2)
      expect(e21.episode).to eq(1)
    end
  end

  describe 'compares' do
    it 'handles equality' do
      expect(e11).to eq(e11)
      expect(e12).to eq(e12)
      expect(e21).to eq(e21)
    end

    it 'handles relative ordering' do
      expect(e11).to be < e12
      expect(e11).to be < e21
      expect(e12).to be < e21

      expect(e21).to be > e11
      expect(e21).to be > e12
      expect(e12).to be > e11
    end

    it 'uniqs correctly' do
      expect([e11, e11].uniq).to eq([e11])
      expect([e11, e12].uniq).to eq([e11, e12])
      expect([e11, e12, e11].uniq).to eq([e11, e12])
    end

    it 'sorts correctly' do
      expect([e21, e12, e11].sort).to eq([e11, e12, e21])
    end
  end

  describe 'to_s' do
    it 'formats' do
      expect(e11.to_s).to eq('S01E01')
      expect(e12.to_s).to eq('S01E02')
      expect(e21.to_s).to eq('S02E01')
    end
  end

  describe 'from_s' do
    it 'parses' do
      expect(EpisodeID.from_s('S01E01')).to eq(e11)
      expect(EpisodeID.from_s('S1E2')).to eq(e12)
      expect(EpisodeID.from_s('S000002E000001')).to eq(e21)

      expect(EpisodeID.from_s('s01e01')).to eq(nil)
      expect(EpisodeID.from_s('1xE01')).to eq(nil)
      expect(EpisodeID.from_s('101')).to eq(nil)
    end
  end
  
  describe 'from_release' do
    it 'parses' do
      expect(EpisodeID.from_release('Series.S01E01.720p')).to eq(e11)
      expect(EpisodeID.from_release('Series.s01e01.720p')).to eq(e11)
      expect(EpisodeID.from_release('Series.1x01.720p')).to eq(e11)
      expect(EpisodeID.from_release('123.S01E01.720p')).to eq(e11)
      expect(EpisodeID.from_release('Series.S01E01.123')).to eq(e11)

      expect(EpisodeID.from_release('Series.101.720p')).to eq(nil)
      expect(EpisodeID.from_release('S01E01')).to eq(nil)
      expect(EpisodeID.from_release('Series S02 720p')).to eq(nil)
    end
  end
end

