# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Lists
      class ImportFromMusicbrainzSeriesTest < ActiveSupport::TestCase
        def setup
          @list = lists(:music_albums_list)
        end

        test "call successfully imports albums from series" do
          # Clear any existing list items to test import functionality in isolation
          @list.list_items.destroy_all
          initial_count = @list.list_items.count
          # Mock series search response
          series_search = mock
          series_search.expects(:browse_series_with_release_groups)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "release_group",
                    "release_group" => {
                      "id" => "release-group-1"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  },
                  {
                    "target-type" => "release_group",
                    "release_group" => {
                      "id" => "release-group-2"
                    },
                    "attribute-values" => {
                      "number" => "2"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          # Mock album importer to return successful imports (use albums not in fixtures)
          album1 = music_albums(:wish_you_were_here)  # Not in fixture list items
          album2 = music_albums(:animals)             # Not in fixture list items

          import_result1 = DataImporters::ImportResult.new(
            item: album1,
            provider_results: [],
            success: true
          )
          import_result2 = DataImporters::ImportResult.new(
            item: album2,
            provider_results: [],
            success: true
          )

          # Use different albums to avoid fixture conflicts
          DataImporters::Music::Album::Importer.stubs(:call)
            .with(release_group_musicbrainz_id: "release-group-1")
            .returns(import_result1)

          DataImporters::Music::Album::Importer.stubs(:call)
            .with(release_group_musicbrainz_id: "release-group-2")
            .returns(import_result2)

          result = ImportFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 2 of 2 albums", result[:message]
          assert_equal 2, result[:imported_count]
          assert_equal 2, result[:total_count]

          # Check that the correct number of items were imported
          # (Note: some may have been updates to existing items rather than new additions)
          final_count = @list.reload.list_items.count
          assert final_count >= initial_count, "Should not have fewer items than before"
          assert_equal 2, result[:imported_count], "Should have imported exactly 2 items"

          # Check positions
          item1 = @list.list_items.find_by(listable: album1)
          item2 = @list.list_items.find_by(listable: album2)
          assert_equal 1, item1.position
          assert_equal 2, item2.position
        end

        test "call handles series search failure" do
          series_search = mock
          series_search.expects(:browse_series_with_release_groups)
            .with("test-series-mbid-123")
            .returns(
              success: false,
              errors: ["Series not found"]
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          result = ImportFromMusicbrainzSeries.call(list: @list)

          refute result[:success]
          assert_equal "Failed to fetch series data", result[:message]
          assert_equal 0, result[:imported_count]
        end

        test "call handles album import failures gracefully" do
          # Count existing list items before import
          initial_count = @list.list_items.count
          # Mock series search response
          series_search = mock
          series_search.expects(:browse_series_with_release_groups)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "release_group",
                    "release_group" => {
                      "id" => "release-group-1"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          # Mock album importer to fail
          failed_result = DataImporters::ImportResult.new(
            item: nil,
            provider_results: [],
            success: false
          )

          DataImporters::Music::Album::Importer.stubs(:call)
            .with(release_group_musicbrainz_id: "release-group-1")
            .returns(failed_result)

          result = ImportFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 0 of 1 albums", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal 1, result[:total_count]

          # Check that no new list items were created (only existing fixtures remain)
          assert_equal initial_count, @list.reload.list_items.count
        end

        test "call skips existing albums in list" do
          album = music_albums(:dark_side_of_the_moon) # This album is already in the list via fixtures
          initial_count = @list.list_items.count

          # Mock series search response
          series_search = mock
          series_search.expects(:browse_series_with_release_groups)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "release_group",
                    "release_group" => {
                      "id" => "release-group-1"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          # Mock album importer to return the same album
          import_result = DataImporters::ImportResult.new(
            item: album,
            provider_results: [],
            success: true
          )

          DataImporters::Music::Album::Importer.stubs(:call)
            .with(release_group_musicbrainz_id: "release-group-1")
            .returns(import_result)

          result = ImportFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 1 of 1 albums", result[:message]

          # Should still have the same number of list items (no duplicates created)
          assert_equal initial_count, @list.reload.list_items.count
        end

        test "call returns failure for list without musicbrainz_series_id" do
          list_without_series = lists(:music_songs_list) # This fixture has no series ID

          result = ImportFromMusicbrainzSeries.call(list: list_without_series)

          refute result[:success]
          assert_equal "List must have musicbrainz_series_id", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal 0, result[:total_count]
        end

        test "call returns failure for non-music-albums list" do
          # Use music_songs_list - it has musicbrainz_series_id but wrong type
          non_albums_list = lists(:music_songs_list)
          non_albums_list.update!(musicbrainz_series_id: "test-series-123")

          result = ImportFromMusicbrainzSeries.call(list: non_albums_list)

          refute result[:success]
          assert_equal "List must be a Music::Albums::List", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal 0, result[:total_count]
        end

        test "call handles missing release group relations" do
          # Count existing list items before import
          initial_count = @list.list_items.count
          # Mock series search response with no relations
          series_search = mock
          series_search.expects(:browse_series_with_release_groups)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => []
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          result = ImportFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 0 of 0 albums", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal initial_count, @list.reload.list_items.count
        end
      end
    end
  end
end
