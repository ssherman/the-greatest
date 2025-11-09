require "test_helper"

module Actions
  module Admin
    module Music
      class GenerateArtistDescriptionTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @artist1 = music_artists(:david_bowie)
          @artist2 = music_artists(:the_beatles)
        end

        test "should queue job for single artist" do
          ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist1.id).once

          result = GenerateArtistDescription.call(
            user: @admin_user,
            models: [@artist1]
          )

          assert result.success?
          assert_equal "1 artist(s) queued for AI description generation.", result.message
        end

        test "should queue jobs for multiple artists" do
          ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist1.id).once
          ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist2.id).once

          result = GenerateArtistDescription.call(
            user: @admin_user,
            models: [@artist1, @artist2]
          )

          assert result.success?
          assert_equal "2 artist(s) queued for AI description generation.", result.message
        end

        test "should have correct metadata" do
          assert_equal "Generate AI Description", GenerateArtistDescription.name
          assert_equal "This will generate AI descriptions for the selected artist(s) in the background.", GenerateArtistDescription.message
          assert_equal "Generate Descriptions", GenerateArtistDescription.confirm_button_label
        end
      end
    end
  end
end
