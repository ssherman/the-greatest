require "test_helper"

class Music::CalculateArtistRankingJobTest < ActiveSupport::TestCase
  def setup
    @artist = music_artists(:pink_floyd)
    @config = ranking_configurations(:music_artists_global)
  end

  test "perform executes without error when configuration exists" do
    assert_nothing_raised do
      Music::CalculateArtistRankingJob.new.perform(@artist.id)
    end
  end

  test "perform handles missing configuration" do
    Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

    assert_nothing_raised do
      Music::CalculateArtistRankingJob.new.perform(@artist.id)
    end
  end
end
