require "test_helper"

module Actions
  module Admin
    module Music
      class MergeSongTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @source_song = music_songs(:money)
          @target_song = music_songs(:time)
        end

        test "should merge songs successfully" do
          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song],
            fields: {
              source_song_id: @source_song.id,
              confirm_merge: "1"
            }
          )

          assert result.success?
          assert_match(/Successfully merged/, result.message)
        end

        test "should reject merge without source_song_id" do
          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song],
            fields: {
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_equal "Please enter the ID of the song to merge.", result.message
        end

        test "should reject merge without confirmation" do
          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song],
            fields: {
              source_song_id: @source_song.id
            }
          )

          assert result.error?
          assert_equal "Please confirm you understand this action cannot be undone.", result.message
        end

        test "should reject merge with invalid source song id" do
          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song],
            fields: {
              source_song_id: 99999,
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_match(/not found/, result.message)
        end

        test "should reject self-merge" do
          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song],
            fields: {
              source_song_id: @target_song.id,
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_match(/Cannot merge a song with itself/, result.message)
        end

        test "should reject multiple song selection" do
          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song, @source_song],
            fields: {
              source_song_id: @source_song.id,
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_equal "This action can only be performed on a single song.", result.message
        end

        test "reports a warning, not a plain success, when the post-commit follow-up fails" do
          source_id = @source_song.id
          ::Music::Song::Merger.any_instance.stubs(:schedule_ranking_recalculation)
            .raises(StandardError.new("redis down"))

          result = MergeSong.call(
            user: @admin_user,
            models: [@target_song],
            fields: {source_song_id: source_id, confirm_merge: "1"}
          )

          assert result.warning?, result.message
          assert_not result.success?, "a warning must not also report as a plain success"
          assert_includes result.message, "could not be scheduled"
          assert_includes result.message, "redis down"
          assert_not ::Music::Song.exists?(source_id), "the merge itself must still have committed"
        end
      end
    end
  end
end
