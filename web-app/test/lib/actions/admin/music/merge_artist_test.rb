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
      end
    end
  end
end
