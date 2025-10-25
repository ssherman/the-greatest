require "test_helper"

class Music::CalculateAllArtistsRankingsJobTest < ActiveSupport::TestCase
  def setup
    @config = ranking_configurations(:music_artists_global)
  end

  test "perform executes without error" do
    assert_nothing_raised do
      Music::CalculateAllArtistsRankingsJob.new.perform(@config.id)
    end
  end
end
