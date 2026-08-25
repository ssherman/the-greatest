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

        test "should reject merge when confirmation checkbox is unchecked (string '0')" do
          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: @source_album.id, confirm_merge: "0"}
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
          source_title = @source_album.title
          source_id = @source_album.id

          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: source_id, confirm_merge: "1"}
          )

          assert result.success?, result.message
          assert_includes result.message, "Successfully merged"
          assert_includes result.message, source_title
          assert_includes result.message, @target_album.title
          assert_not ::Music::Album.exists?(source_id), "the source album must actually be gone"
        end

        test "reports a warning, not a plain success, when the post-commit follow-up fails" do
          source_id = @source_album.id
          ::Music::Album::Merger.any_instance.stubs(:reindex_target_album)
            .raises(StandardError.new("opensearch down"))

          result = MergeAlbum.call(
            user: @admin_user,
            models: [@target_album],
            fields: {source_album_id: source_id, confirm_merge: "1"}
          )

          assert result.warning?, result.message
          assert_not result.success?, "a warning must not also report as a plain success"
          assert_includes result.message, "could not be scheduled"
          assert_includes result.message, "opensearch down"
          assert_not ::Music::Album.exists?(source_id), "the merge itself must still have committed"
        end
      end
    end
  end
end
