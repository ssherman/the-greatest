require "test_helper"

module Actions
  module Admin
    module Music
      class RefreshArtistRankingTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @artist = music_artists(:david_bowie)
        end

        test "should queue job for single artist" do
          ::Music::CalculateArtistRankingJob.expects(:perform_async).with(@artist.id).once

          result = RefreshArtistRanking.call(
            user: @admin_user,
            models: [@artist]
          )

          assert result.success?
          assert_equal "Artist ranking calculation queued for #{@artist.name}.", result.message
        end

        test "should return error when given multiple artists" do
          artist2 = music_artists(:the_beatles)

          ::Music::CalculateArtistRankingJob.expects(:perform_async).never

          result = RefreshArtistRanking.call(
            user: @admin_user,
            models: [@artist, artist2]
          )

          assert result.error?
          assert_equal "This action can only be performed on a single artist.", result.message
        end

        test "should have correct metadata" do
          assert_equal "Refresh Artist Ranking", RefreshArtistRanking.name
          assert_equal "This will recalculate this artist's ranking based on their albums and songs.", RefreshArtistRanking.message
        end

        test "should only be visible on show view" do
          assert RefreshArtistRanking.visible?(view: :show)
          assert_not RefreshArtistRanking.visible?(view: :index)
          assert_not RefreshArtistRanking.visible?(view: :edit)
        end
      end
    end
  end
end
