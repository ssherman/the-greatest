require "test_helper"

module Actions
  module Admin
    module Music
      class MergeAlbumTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @target_album = music_albums(:dark_side_of_the_moon)
          @source_album = music_albums(:wish_you_were_here)
        end

        test "should reject merge without source_album_id" do
          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {confirm_merge: "1"}
          )

          assert result.error?
          assert_equal "Please enter the ID of the album to merge.", result.message
        end

        test "should reject merge without confirmation" do
          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: @source_album.id}
          )

          assert result.error?
          assert_equal "Please confirm you understand this action cannot be undone.", result.message
        end

        test "should reject merge with invalid source album id" do
          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: 999999, confirm_merge: "1"}
          )

          assert result.error?
          assert_equal "Album with ID 999999 not found.", result.message
        end

        test "should reject self-merge" do
          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: @target_album.id, confirm_merge: "1"}
          )

          assert result.error?
          assert_equal "Cannot merge an album with itself. Please enter a different album ID.", result.message
        end

        test "should reject multiple album selection" do
          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album, @source_album],
            fields: {source_album_id: @source_album.id, confirm_merge: "1"}
          )

          assert result.error?
          assert_equal "This action can only be performed on a single album.", result.message
        end

        test "should merge albums successfully" do
          merger_result = Struct.new(:success?, :errors).new(true, [])
          ::Music::Album::Merger.expects(:call)
            .with(source: @source_album, target: @target_album)
            .returns(merger_result)

          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: @source_album.id, confirm_merge: "1"}
          )

          assert result.success?
          assert_includes result.message, "Successfully merged"
          assert_includes result.message, @source_album.title
          assert_includes result.message, @target_album.title
        end
      end
    end
  end
end
