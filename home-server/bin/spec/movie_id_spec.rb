# frozen_string_literal: true

require 'movie_id'
require 'rspec'

describe 'MovieID' do
  def anh
    MovieID.new('A New Hope', 1977)
  end

  def onef
    MovieID.new('1984', '1984')
  end

  def xm
    MovieID.new('X-Men: Apocalypse', '2016')
  end

  def tam
    MovieID.new('12 Angry Men', 1957)
  end

  def tto
    MovieID.new('2001 A Space Odyssey', 1968)
  end

  describe 'initialize' do
    it 'stores attributes' do
      expect(anh.title).to eq('A New Hope')
      expect(anh.year).to eq(1977)
    end

    it 'handles string input' do
      expect(xm.title).to eq('X-Men: Apocalypse')
      expect(onef.year).to eq(1984)
    end
  end

  describe 'compares' do
    it 'handles equality' do
      expect(anh).to eq(anh)
      expect(onef).to eq(onef)
    end
  end

  describe 'to_s' do
    it 'formats' do
      expect(anh.to_s).to eq('A New Hope (1977)')
      expect(onef.to_s).to eq('1984 (1984)')
    end
  end

  describe 'from_s' do
    it 'parses' do
      expect(MovieID.from_s('A New Hope (1977)')).to eq(anh)
      expect(MovieID.from_s('1984 (1984)')).to eq(onef)
      expect(MovieID.from_s('2001 A Space Odyssey (1968)')).to eq(tto)

      expect(MovieID.from_s('1984')).to eq(nil)
    end
  end

  describe 'from_release' do
    it 'parses' do
      expect(MovieID.from_release('A.New.Hope.1977.720p')).to eq(anh)
      expect(MovieID.from_release('A.New.Hope.1977.123')).to eq(anh)
      expect(MovieID.from_release('1984.1984.720p')).to eq(onef)
      expect(MovieID.from_release('X-Men:.Apocalypse.2016.720p')).to eq(xm)
      expect(MovieID.from_release('12.Angry.men.1957.720p')).to eq(tam)
      expect(MovieID.from_release('2001.A.Space.Odyssey.1968.720p')).to eq(tto)

      expect(MovieID.from_release('A.New.Hope.123.720p')).to eq(nil)
      expect(MovieID.from_release('1984.720p')).to eq(nil)
    end
  end
end
