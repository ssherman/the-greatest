# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Lists
      class ImportSongsFromMusicbrainzSeriesTest < ActiveSupport::TestCase
        def setup
          @list = lists(:music_songs_list)
          @list.update!(musicbrainz_series_id: "test-series-mbid-123")
        end

        test "call successfully imports songs from series" do
          @list.list_items.destroy_all
          initial_count = @list.list_items.count

          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "recording",
                    "recording" => {
                      "id" => "recording-1",
                      "title" => "Test Song 1"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  },
                  {
                    "target-type" => "recording",
                    "recording" => {
                      "id" => "recording-2",
                      "title" => "Test Song 2"
                    },
                    "attribute-values" => {
                      "number" => "2"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          song1 = music_songs(:time)
          song2 = music_songs(:money)

          import_result1 = DataImporters::ImportResult.new(
            item: song1,
            provider_results: [],
            success: true
          )
          import_result2 = DataImporters::ImportResult.new(
            item: song2,
            provider_results: [],
            success: true
          )

          DataImporters::Music::Song::Importer.stubs(:call)
            .with(musicbrainz_recording_id: "recording-1")
            .returns(import_result1)

          DataImporters::Music::Song::Importer.stubs(:call)
            .with(musicbrainz_recording_id: "recording-2")
            .returns(import_result2)

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 2 of 2 songs", result[:message]
          assert_equal 2, result[:imported_count]
          assert_equal 2, result[:total_count]

          final_count = @list.reload.list_items.count
          assert final_count >= initial_count
          assert_equal 2, result[:imported_count]

          item1 = @list.list_items.find_by(listable: song1)
          item2 = @list.list_items.find_by(listable: song2)
          assert_equal 1, item1.position
          assert_equal 2, item2.position
        end

        test "call handles series search failure" do
          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: false,
              errors: ["Series not found"]
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          refute result[:success]
          assert_equal "Failed to fetch series data", result[:message]
          assert_equal 0, result[:imported_count]
        end

        test "call handles song import failures gracefully" do
          initial_count = @list.list_items.count

          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "recording",
                    "recording" => {
                      "id" => "recording-1",
                      "title" => "Test Song"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          failed_result = DataImporters::ImportResult.new(
            item: nil,
            provider_results: [],
            success: false
          )

          DataImporters::Music::Song::Importer.stubs(:call)
            .with(musicbrainz_recording_id: "recording-1")
            .returns(failed_result)

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 0 of 1 songs", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal 1, result[:total_count]

          assert_equal initial_count, @list.reload.list_items.count
        end

        test "call skips existing songs in list" do
          song = music_songs(:time)
          @list.list_items.create!(listable: song, position: 1)
          initial_count = @list.list_items.count

          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "recording",
                    "recording" => {
                      "id" => "recording-1",
                      "title" => "Time"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          import_result = DataImporters::ImportResult.new(
            item: song,
            provider_results: [],
            success: true
          )

          DataImporters::Music::Song::Importer.stubs(:call)
            .with(musicbrainz_recording_id: "recording-1")
            .returns(import_result)

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 1 of 1 songs", result[:message]

          assert_equal initial_count, @list.reload.list_items.count
        end

        test "call returns failure for list without musicbrainz_series_id" do
          list_without_series = lists(:music_songs_list)
          list_without_series.update!(musicbrainz_series_id: nil)

          result = ImportSongsFromMusicbrainzSeries.call(list: list_without_series)

          refute result[:success]
          assert_equal "List must have musicbrainz_series_id", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal 0, result[:total_count]
        end

        test "call returns failure for non-music-songs list" do
          non_songs_list = lists(:music_albums_list)
          non_songs_list.update!(musicbrainz_series_id: "test-series-123")

          result = ImportSongsFromMusicbrainzSeries.call(list: non_songs_list)

          refute result[:success]
          assert_equal "List must be a Music::Songs::List", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal 0, result[:total_count]
        end

        test "call handles missing recording relations" do
          initial_count = @list.list_items.count

          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => []
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 0 of 0 songs", result[:message]
          assert_equal 0, result[:imported_count]
          assert_equal initial_count, @list.reload.list_items.count
        end

        test "call enriches existing songs without artists" do
          song = music_songs(:time)
          song.song_artists.destroy_all
          song.identifiers.create!(
            identifier_type: :music_musicbrainz_recording_id,
            value: "recording-1"
          )

          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "recording",
                    "recording" => {
                      "id" => "recording-1",
                      "title" => "Time"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          enriched_result = DataImporters::ImportResult.new(
            item: song,
            provider_results: [],
            success: true
          )

          DataImporters::Music::Song::Importer.expects(:call)
            .with(musicbrainz_recording_id: "recording-1", force_providers: true)
            .returns(enriched_result)

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 1 of 1 songs", result[:message]
        end

        test "call does not enrich existing songs that already have artists" do
          song = music_songs(:time)
          song.identifiers.create!(
            identifier_type: :music_musicbrainz_recording_id,
            value: "recording-1"
          )

          series_search = mock
          series_search.expects(:browse_series_with_recordings)
            .with("test-series-mbid-123")
            .returns(
              success: true,
              data: {
                "relations" => [
                  {
                    "target-type" => "recording",
                    "recording" => {
                      "id" => "recording-1",
                      "title" => "Time"
                    },
                    "attribute-values" => {
                      "number" => "1"
                    }
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::SeriesSearch.stubs(:new).returns(series_search)

          DataImporters::Music::Song::Importer.expects(:call).never

          result = ImportSongsFromMusicbrainzSeries.call(list: @list)

          assert result[:success]
          assert_equal "Imported 1 of 1 songs", result[:message]
        end
      end
    end
  end
end
