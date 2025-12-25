require "test_helper"

module Services
  module Lists
    module Music
      module Songs
        class ListItemEnricherTest < ActiveSupport::TestCase
          setup do
            @list = lists(:music_songs_list)
            @song = music_songs(:time)
            @list_item = ListItem.create!(
              list: @list,
              listable_type: "Music::Song",
              listable_id: nil,
              verified: false,
              position: 1,
              metadata: {
                "title" => "Time",
                "artists" => ["Pink Floyd"],
                "album" => "The Dark Side of the Moon",
                "release_year" => 1973
              }
            )
          end

          teardown do
            @list_item&.destroy
          end

          test "returns opensearch result when local song found" do
            opensearch_results = [{id: @song.id.to_s, score: 15.0}]
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns(opensearch_results)

            result = ListItemEnricher.call(list_item: @list_item)

            assert result[:success]
            assert_equal :opensearch, result[:source]
            assert_equal @song.id, result[:song_id]
            assert result[:data]["opensearch_match"]
          end

          test "returns musicbrainz result when opensearch finds nothing" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            mb_response = {
              success: true,
              data: {
                "recordings" => [{
                  "id" => "abc123-def456",
                  "title" => "Time",
                  "artist-credit" => [
                    {"artist" => {"id" => "artist-mbid-123", "name" => "Pink Floyd"}}
                  ]
                }]
              }
            }
            ::Music::Musicbrainz::Search::RecordingSearch.any_instance.stubs(:search_by_artist_and_title).returns(mb_response)
            ::Music::Song.stubs(:with_identifier).returns(::Music::Song.none)

            result = ListItemEnricher.call(list_item: @list_item)

            assert result[:success]
            assert_equal :musicbrainz, result[:source]
            assert result[:data]["musicbrainz_match"]
            assert_equal "abc123-def456", result[:data]["mb_recording_id"]
          end

          test "returns not_found when neither source matches" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            mb_response = {success: true, data: {"recordings" => []}}
            ::Music::Musicbrainz::Search::RecordingSearch.any_instance.stubs(:search_by_artist_and_title).returns(mb_response)

            result = ListItemEnricher.call(list_item: @list_item)

            assert_not result[:success]
            assert_equal :not_found, result[:source]
          end

          test "updates list_item.listable_id when song found via OpenSearch" do
            opensearch_results = [{id: @song.id.to_s, score: 15.0}]
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns(opensearch_results)

            ListItemEnricher.call(list_item: @list_item)

            @list_item.reload
            assert_equal @song.id, @list_item.listable_id
          end

          test "updates list_item.listable_id when song found via MusicBrainz MBID" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            mb_response = {
              success: true,
              data: {
                "recordings" => [{
                  "id" => "existing-mbid",
                  "title" => "Time",
                  "artist-credit" => []
                }]
              }
            }
            ::Music::Musicbrainz::Search::RecordingSearch.any_instance.stubs(:search_by_artist_and_title).returns(mb_response)

            existing_song = music_songs(:money)
            scope_mock = mock
            scope_mock.stubs(:first).returns(existing_song)
            ::Music::Song.stubs(:with_identifier).with(:music_musicbrainz_recording_id, "existing-mbid").returns(scope_mock)

            result = ListItemEnricher.call(list_item: @list_item)

            @list_item.reload
            assert_equal existing_song.id, @list_item.listable_id
            assert_equal existing_song.id, result[:data]["song_id"]
          end

          test "updates list_item.metadata with enrichment data" do
            opensearch_results = [{id: @song.id.to_s, score: 18.5}]
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns(opensearch_results)

            ListItemEnricher.call(list_item: @list_item)

            @list_item.reload
            assert_equal @song.id, @list_item.metadata["song_id"]
            assert_equal @song.title, @list_item.metadata["song_name"]
            assert @list_item.metadata["opensearch_match"]
            assert_equal 18.5, @list_item.metadata["opensearch_score"]
          end

          test "handles missing title gracefully" do
            @list_item.update!(metadata: {"artists" => ["Pink Floyd"]})

            result = ListItemEnricher.call(list_item: @list_item)

            assert_not result[:success]
            assert_equal :not_found, result[:source]
          end

          test "handles missing artists gracefully" do
            @list_item.update!(metadata: {"title" => "Time"})

            result = ListItemEnricher.call(list_item: @list_item)

            assert_not result[:success]
            assert_equal :not_found, result[:source]
          end

          test "handles OpenSearch errors gracefully" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).raises(StandardError.new("Connection timeout"))

            mb_response = {success: true, data: {"recordings" => []}}
            ::Music::Musicbrainz::Search::RecordingSearch.any_instance.stubs(:search_by_artist_and_title).returns(mb_response)

            result = ListItemEnricher.call(list_item: @list_item)

            assert_not result[:success]
            assert_equal :not_found, result[:source]
          end

          test "handles MusicBrainz errors gracefully" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])
            ::Music::Musicbrainz::Search::RecordingSearch.any_instance.stubs(:search_by_artist_and_title).raises(StandardError.new("API error"))

            result = ListItemEnricher.call(list_item: @list_item)

            assert_not result[:success]
            assert_equal :not_found, result[:source]
          end

          test "preserves original metadata when enriching" do
            opensearch_results = [{id: @song.id.to_s, score: 15.0}]
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns(opensearch_results)

            ListItemEnricher.call(list_item: @list_item)

            @list_item.reload
            assert_equal "Time", @list_item.metadata["title"]
            assert_equal ["Pink Floyd"], @list_item.metadata["artists"]
            assert_equal "The Dark Side of the Moon", @list_item.metadata["album"]
            assert_equal 1973, @list_item.metadata["release_year"]
          end

          test "stores musicbrainz artist info when found" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            mb_response = {
              success: true,
              data: {
                "recordings" => [{
                  "id" => "rec-mbid",
                  "title" => "Time",
                  "artist-credit" => [
                    {"artist" => {"id" => "artist-1", "name" => "Artist One"}},
                    {"artist" => {"id" => "artist-2", "name" => "Artist Two"}}
                  ]
                }]
              }
            }
            ::Music::Musicbrainz::Search::RecordingSearch.any_instance.stubs(:search_by_artist_and_title).returns(mb_response)
            ::Music::Song.stubs(:with_identifier).returns(::Music::Song.none)

            ListItemEnricher.call(list_item: @list_item)

            @list_item.reload
            assert_equal ["artist-1", "artist-2"], @list_item.metadata["mb_artist_ids"]
            assert_equal ["Artist One", "Artist Two"], @list_item.metadata["mb_artist_names"]
          end
        end
      end
    end
  end
end
