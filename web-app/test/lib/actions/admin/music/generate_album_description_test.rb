require "test_helper"

module Actions
  module Admin
    module Music
      class GenerateAlbumDescriptionTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @album = music_albums(:dark_side_of_the_moon)
          @album2 = music_albums(:wish_you_were_here)
        end

        test "should queue job for single album" do
          ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album.id)

          result = GenerateAlbumDescription.call(
            user: @admin_user,
            models: [@album]
          )

          assert result.success?
          assert_equal "1 album(s) queued for AI description generation.", result.message
        end

        test "should queue jobs for multiple albums" do
          ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album.id)
          ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album2.id)

          result = GenerateAlbumDescription.call(
            user: @admin_user,
            models: [@album, @album2]
          )

          assert result.success?
          assert_equal "2 album(s) queued for AI description generation.", result.message
        end

        test "should return correct count in message" do
          ::Music::AlbumDescriptionJob.stubs(:perform_async)

          result = GenerateAlbumDescription.call(
            user: @admin_user,
            models: [@album, @album2]
          )

          assert_includes result.message, "2 album(s)"
        end

        test "should handle empty models array" do
          result = GenerateAlbumDescription.call(
            user: @admin_user,
            models: []
          )

          assert result.success?
          assert_equal "0 album(s) queued for AI description generation.", result.message
        end
      end
    end
  end
end
