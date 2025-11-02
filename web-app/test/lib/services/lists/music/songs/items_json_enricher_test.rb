require "test_helper"

module Services
  module Lists
    module Music
      module Songs
        class ItemsJsonEnricherTest < ActiveSupport::TestCase
          def setup
            @list = lists(:music_songs_list_with_items_json)
          end

          test "call successfully enriches items_json with MusicBrainz data" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            search_service = mock

            beatles_response = {
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
                    "title" => "Come Together",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
                          "name" => "The Beatles"
                        }
                      }
                    ]
                  }
                ]
              }
            }

            queen_response = {
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => "b1a9c0e1-0bb8-4fad-8ddb-78a22d1e6c4e",
                    "title" => "Bohemian Rhapsody",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "0383dadf-2a4e-4d10-a46a-e9e041da8eb3",
                          "name" => "Queen"
                        }
                      }
                    ]
                  }
                ]
              }
            }

            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Come Together")
              .returns(beatles_response)

            search_service.expects(:search_by_artist_and_title)
              .with("Queen", "Bohemian Rhapsody")
              .returns(queen_response)

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 2, result[:enriched_count]
            assert_equal 0, result[:skipped_count]
            assert_equal 2, result[:total_count]
            assert_equal 0, result[:opensearch_matches]
            assert_equal 2, result[:musicbrainz_matches]

            enriched_data = @list.reload.items_json["songs"]

            first_song = enriched_data[0]
            assert_equal "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc", first_song["mb_recording_id"]
            assert_equal "Come Together", first_song["mb_recording_name"]
            assert_equal ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"], first_song["mb_artist_ids"]
            assert_equal ["The Beatles"], first_song["mb_artist_names"]
            assert_equal true, first_song["musicbrainz_match"]
            assert_nil first_song["song_id"]

            second_song = enriched_data[1]
            assert_equal "b1a9c0e1-0bb8-4fad-8ddb-78a22d1e6c4e", second_song["mb_recording_id"]
            assert_equal "Bohemian Rhapsody", second_song["mb_recording_name"]
            assert_equal ["0383dadf-2a4e-4d10-a46a-e9e041da8eb3"], second_song["mb_artist_ids"]
            assert_equal ["Queen"], second_song["mb_artist_names"]
            assert_equal true, second_song["musicbrainz_match"]
          end

          test "call enriches items_json with song_id when song exists in database" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            existing_song = music_songs(:time)

            existing_song.identifiers.create!(
              identifier_type: :music_musicbrainz_recording_id,
              value: "4e6d8091-d98b-44a8-b0bb-1b8d79d1b9f9"
            )

            @list.update!(
              items_json: {
                "songs" => [
                  {
                    "rank" => 1,
                    "title" => "Time",
                    "artists" => ["Pink Floyd"],
                    "release_year" => 1973
                  }
                ]
              }
            )

            search_service = mock
            search_response = {
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => "4e6d8091-d98b-44a8-b0bb-1b8d79d1b9f9",
                    "title" => "Time",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                          "name" => "Pink Floyd"
                        }
                      }
                    ]
                  }
                ]
              }
            }

            search_service.expects(:search_by_artist_and_title)
              .with("Pink Floyd", "Time")
              .returns(search_response)

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]

            enriched_song = @list.reload.items_json["songs"][0]
            assert_equal existing_song.id, enriched_song["song_id"]
            assert_equal existing_song.title, enriched_song["song_name"]
          end

          test "call handles multi-artist songs by joining names" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            @list.update!(
              items_json: {
                "songs" => [
                  {
                    "rank" => 1,
                    "title" => "Empire State of Mind",
                    "artists" => ["Jay-Z", "Alicia Keys"],
                    "release_year" => 2009
                  }
                ]
              }
            )

            search_service = mock
            search_response = {
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => "test-multi-artist-id",
                    "title" => "Empire State of Mind",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "artist-1-id",
                          "name" => "Jay-Z"
                        }
                      },
                      {
                        "artist" => {
                          "id" => "artist-2-id",
                          "name" => "Alicia Keys"
                        }
                      }
                    ]
                  }
                ]
              }
            }

            search_service.expects(:search_by_artist_and_title)
              .with("Jay-Z, Alicia Keys", "Empire State of Mind")
              .returns(search_response)

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]

            enriched_song = @list.reload.items_json["songs"][0]
            assert_equal ["artist-1-id", "artist-2-id"], enriched_song["mb_artist_ids"]
            assert_equal ["Jay-Z", "Alicia Keys"], enriched_song["mb_artist_names"]
          end

          test "call skips entries without MusicBrainz matches and logs warnings" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            search_service = mock

            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Come Together")
              .returns(
                success: true,
                data: {
                  "recordings" => [
                    {
                      "id" => "test-id",
                      "title" => "Come Together",
                      "artist-credit" => [
                        {"artist" => {"id" => "artist-id", "name" => "The Beatles"}}
                      ]
                    }
                  ]
                }
              )

            search_service.expects(:search_by_artist_and_title)
              .with("Queen", "Bohemian Rhapsody")
              .returns(success: false, data: {"recordings" => []})

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 1, result[:enriched_count]
            assert_equal 1, result[:skipped_count]
            assert_equal 2, result[:total_count]

            enriched_data = @list.reload.items_json["songs"]
            assert enriched_data[0].key?("mb_recording_id")

            refute enriched_data[1].key?("mb_recording_id")
            assert_equal "Bohemian Rhapsody", enriched_data[1]["title"]
          end

          test "call validates list is a Music::Songs::List" do
            books_list = lists(:books_list)

            error = assert_raises(ArgumentError) do
              ItemsJsonEnricher.call(list: books_list)
            end

            assert_equal "List must be a Music::Songs::List", error.message
          end

          test "call validates list has items_json populated" do
            empty_list = lists(:music_songs_list)
            empty_list.update!(items_json: nil)

            error = assert_raises(ArgumentError) do
              ItemsJsonEnricher.call(list: empty_list)
            end

            assert_equal "List must have items_json populated", error.message
          end

          test "call validates items_json contains songs array" do
            @list.update!(items_json: {"foo" => "bar"})

            error = assert_raises(ArgumentError) do
              ItemsJsonEnricher.call(list: @list)
            end

            assert_equal "List items_json must contain songs array", error.message
          end

          test "call handles search service errors gracefully and skips entries" do
            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).raises(StandardError.new("Test error"))

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 0, result[:enriched_count]
            assert_equal 2, result[:skipped_count]
            assert_equal 2, result[:total_count]
          end

          test "call handles empty recordings array" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            search_service = mock

            search_service.expects(:search_by_artist_and_title)
              .twice
              .returns(success: true, data: {"recordings" => []})

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 0, result[:enriched_count]
            assert_equal 2, result[:skipped_count]
          end

          test "call handles missing artist-credit in response" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            search_service = mock

            search_response = {
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => "test-id",
                    "title" => "Come Together"
                  }
                ]
              }
            }

            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Come Together")
              .returns(search_response)

            search_service.expects(:search_by_artist_and_title)
              .with("Queen", "Bohemian Rhapsody")
              .returns(success: false, data: {"recordings" => []})

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 1, result[:enriched_count]

            enriched_song = @list.reload.items_json["songs"][0]
            assert_equal [], enriched_song["mb_artist_ids"]
            assert_equal [], enriched_song["mb_artist_names"]
          end

          test "call finds song via OpenSearch and skips MusicBrainz" do
            existing_song = music_songs(:time)

            @list.update!(
              items_json: {
                "songs" => [
                  {
                    "rank" => 1,
                    "title" => "Time",
                    "artists" => ["Pink Floyd"],
                    "release_year" => 1973
                  }
                ]
              }
            )

            opensearch_result = [
              {
                id: existing_song.id.to_s,
                score: 15.5,
                source: {"title" => "Time"}
              }
            ]

            ::Search::Music::Search::SongByTitleAndArtists.expects(:call)
              .with(
                title: "Time",
                artists: ["Pink Floyd"],
                size: 1,
                min_score: 5.0
              )
              .returns(opensearch_result)

            ::Music::Musicbrainz::Search::RecordingSearch.expects(:new).never

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 1, result[:enriched_count]
            assert_equal 1, result[:opensearch_matches]
            assert_equal 0, result[:musicbrainz_matches]

            enriched_song = @list.reload.items_json["songs"][0]
            assert_equal existing_song.id, enriched_song["song_id"]
            assert_equal existing_song.title, enriched_song["song_name"]
            assert_equal true, enriched_song["opensearch_match"]
            assert_equal 15.5, enriched_song["opensearch_score"]
            assert_nil enriched_song["mb_recording_id"]
          end

          test "call falls back to MusicBrainz when OpenSearch finds no match" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).returns([])

            search_service = mock
            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Come Together")
              .returns(
                success: true,
                data: {
                  "recordings" => [
                    {
                      "id" => "test-id",
                      "title" => "Come Together",
                      "artist-credit" => [
                        {"artist" => {"id" => "artist-id", "name" => "The Beatles"}}
                      ]
                    }
                  ]
                }
              )

            search_service.expects(:search_by_artist_and_title)
              .with("Queen", "Bohemian Rhapsody")
              .returns(
                success: true,
                data: {
                  "recordings" => [
                    {
                      "id" => "test-id-2",
                      "title" => "Bohemian Rhapsody",
                      "artist-credit" => [
                        {"artist" => {"id" => "artist-id-2", "name" => "Queen"}}
                      ]
                    }
                  ]
                }
              )

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 2, result[:enriched_count]
            assert_equal 0, result[:opensearch_matches]
            assert_equal 2, result[:musicbrainz_matches]
          end

          test "call handles OpenSearch errors gracefully and falls back to MusicBrainz" do
            ::Search::Music::Search::SongByTitleAndArtists.stubs(:call).raises(StandardError.new("OpenSearch error"))

            search_service = mock
            search_service.expects(:search_by_artist_and_title)
              .twice
              .returns(
                success: true,
                data: {
                  "recordings" => [
                    {
                      "id" => "test-id",
                      "title" => "Test Song",
                      "artist-credit" => [
                        {"artist" => {"id" => "artist-id", "name" => "Test Artist"}}
                      ]
                    }
                  ]
                }
              )

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 2, result[:enriched_count]
            assert_equal 0, result[:opensearch_matches]
            assert_equal 2, result[:musicbrainz_matches]
          end

          test "call tracks mixed OpenSearch and MusicBrainz matches" do
            existing_song = music_songs(:time)

            @list.update!(
              items_json: {
                "songs" => [
                  {
                    "rank" => 1,
                    "title" => "Time",
                    "artists" => ["Pink Floyd"],
                    "release_year" => 1973
                  },
                  {
                    "rank" => 2,
                    "title" => "Unknown Song",
                    "artists" => ["Unknown Artist"],
                    "release_year" => 2020
                  }
                ]
              }
            )

            opensearch_result = [
              {
                id: existing_song.id.to_s,
                score: 15.5,
                source: {"title" => "Time"}
              }
            ]

            ::Search::Music::Search::SongByTitleAndArtists.expects(:call)
              .with(
                title: "Time",
                artists: ["Pink Floyd"],
                size: 1,
                min_score: 5.0
              )
              .returns(opensearch_result)

            ::Search::Music::Search::SongByTitleAndArtists.expects(:call)
              .with(
                title: "Unknown Song",
                artists: ["Unknown Artist"],
                size: 1,
                min_score: 5.0
              )
              .returns([])

            search_service = mock
            search_service.expects(:search_by_artist_and_title)
              .with("Unknown Artist", "Unknown Song")
              .returns(
                success: true,
                data: {
                  "recordings" => [
                    {
                      "id" => "mb-id",
                      "title" => "Unknown Song",
                      "artist-credit" => [
                        {"artist" => {"id" => "mb-artist-id", "name" => "Unknown Artist"}}
                      ]
                    }
                  ]
                }
              )

            ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            assert result[:success]
            assert_equal 2, result[:enriched_count]
            assert_equal 1, result[:opensearch_matches]
            assert_equal 1, result[:musicbrainz_matches]

            enriched_data = @list.reload.items_json["songs"]
            assert_equal true, enriched_data[0]["opensearch_match"]
            assert_equal true, enriched_data[1]["musicbrainz_match"]
          end
        end
      end
    end
  end
end
