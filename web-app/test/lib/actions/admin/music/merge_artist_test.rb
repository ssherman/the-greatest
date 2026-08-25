require "test_helper"

module Actions
  module Admin
    module Music
      class MergeArtistTest < ActiveSupport::TestCase
        setup do
          @admin_user = users(:admin_user)
          @source_artist = music_artists(:beatles_tribute_band)
          @target_artist = music_artists(:the_beatles)
        end

        test "should merge artists successfully" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {
              source_artist_id: @source_artist.id,
              confirm_merge: "1"
            }
          )

          assert result.success?
          assert_match(/Successfully merged/, result.message)
        end

        test "should reject merge without source_artist_id" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_equal "Please select an artist to merge.", result.message
        end

        test "should reject merge without confirmation" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {
              source_artist_id: @source_artist.id
            }
          )

          assert result.error?
          assert_equal "Please confirm you understand this action cannot be undone.", result.message
        end

        test "should reject merge with invalid source artist id" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {
              source_artist_id: 99999,
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_match(/not found/, result.message)
        end

        test "should reject self-merge" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {
              source_artist_id: @target_artist.id,
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_match(/Cannot merge an artist with itself/, result.message)
        end

        test "should reject multiple artist selection" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist, @source_artist],
            fields: {
              source_artist_id: @source_artist.id,
              confirm_merge: "1"
            }
          )

          assert result.error?
          assert_equal "This action can only be performed on a single artist.", result.message
        end

        test "should accept string keys for fields" do
          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {
              "source_artist_id" => @source_artist.id,
              "confirm_merge" => "1"
            }
          )

          assert result.success?
          assert_match(/Successfully merged/, result.message)
        end

        test "reports a warning, not a plain success, when the post-commit follow-up fails" do
          source_id = @source_artist.id
          ::Music::Artist::Merger.any_instance.stubs(:reindex_target_artist)
            .raises(StandardError.new("opensearch down"))

          result = MergeArtist.call(
            user: @admin_user,
            models: [@target_artist],
            fields: {source_artist_id: source_id, confirm_merge: "1"}
          )

          assert result.warning?, result.message
          assert_not result.success?, "a warning must not also report as a plain success"
          assert_includes result.message, "could not be scheduled"
          assert_includes result.message, "opensearch down"
          assert_not ::Music::Artist.exists?(source_id), "the merge itself must still have committed"
        end
      end
    end
  end
end
