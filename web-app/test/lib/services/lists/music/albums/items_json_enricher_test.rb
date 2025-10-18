require "test_helper"

module Services
  module Lists
    module Music
      module Albums
        class ItemsJsonEnricherTest < ActiveSupport::TestCase
          def setup
            @list = lists(:music_albums_list_with_items_json)
          end

          test "call successfully enriches items_json with MusicBrainz data" do
            # Mock MusicBrainz search responses
            search_service = mock

            # Mock response for The Smiths - The Queen Is Dead
            smiths_response = {
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "9bb1e2f4-4e8e-3e9e-9e9e-9e9e9e9e9e9e",
                    "title" => "The Queen Is Dead",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "a3cb23fc-acd3-4ce0-8f36-1e5aa6a18432",
                          "name" => "The Smiths"
                        }
                      }
                    ]
                  }
                ]
              }
            }

            # Mock response for The Beatles - Revolver
            beatles_response = {
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "7c72a5b4-23e3-404f-afe0-f9df359d6e69",
                    "title" => "Revolver",
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

            search_service.expects(:search_by_artist_and_title)
              .with("The Smiths", "The Queen Is Dead")
              .returns(smiths_response)

            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Revolver")
              .returns(beatles_response)

            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

            # Execute enrichment
            result = ItemsJsonEnricher.call(list: @list)

            # Assert successful result
            assert result[:success]
            assert_equal 2, result[:enriched_count]
            assert_equal 0, result[:skipped_count]
            assert_equal 2, result[:total_count]

            # Verify items_json was updated
            enriched_data = @list.reload.items_json["albums"]

            # Verify first album (The Smiths)
            first_album = enriched_data[0]
            assert_equal "9bb1e2f4-4e8e-3e9e-9e9e-9e9e9e9e9e9e", first_album["mb_release_group_id"]
            assert_equal "The Queen Is Dead", first_album["mb_release_group_name"]
            assert_equal ["a3cb23fc-acd3-4ce0-8f36-1e5aa6a18432"], first_album["mb_artist_ids"]
            assert_equal ["The Smiths"], first_album["mb_artist_names"]
            assert_nil first_album["album_id"] # Album doesn't exist in database

            # Verify second album (The Beatles)
            second_album = enriched_data[1]
            assert_equal "7c72a5b4-23e3-404f-afe0-f9df359d6e69", second_album["mb_release_group_id"]
            assert_equal "Revolver", second_album["mb_release_group_name"]
            assert_equal ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"], second_album["mb_artist_ids"]
            assert_equal ["The Beatles"], second_album["mb_artist_names"]
          end

          test "call enriches items_json with album_id when album exists in database" do
            # Create an existing album with MusicBrainz ID
            existing_album = music_albums(:dark_side_of_the_moon)

            # Ensure identifier exists (it's already in fixtures but we verify)
            # The identifier fixtures should already have:
            # dark_side_musicbrainz_release_group with value f5093c06-23e3-404f-afe0-f9df359d6e68

            # Update list with album that matches existing album
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "The Dark Side of the Moon",
                    "artists" => ["Pink Floyd"],
                    "release_year" => nil
                  }
                ]
              }
            )

            # Mock MusicBrainz search response
            search_service = mock
            search_response = {
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "f5093c06-23e3-404f-afe0-f9df359d6e68",
                    "title" => "The Dark Side of the Moon",
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
              .with("Pink Floyd", "The Dark Side of the Moon")
              .returns(search_response)

            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

            # Execute enrichment
            result = ItemsJsonEnricher.call(list: @list)

            # Assert successful result
            assert result[:success]

            # Verify album_id and album_name were added
            enriched_album = @list.reload.items_json["albums"][0]
            assert_equal existing_album.id, enriched_album["album_id"]
            assert_equal existing_album.title, enriched_album["album_name"]
          end

          test "call handles multi-artist albums by joining names" do
            # Update list with multi-artist album
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Watch the Throne",
                    "artists" => ["Jay-Z", "Kanye West"],
                    "release_year" => nil
                  }
                ]
              }
            )

            # Mock MusicBrainz search response
            search_service = mock
            search_response = {
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "test-multi-artist-id",
                    "title" => "Watch the Throne",
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
                          "name" => "Kanye West"
                        }
                      }
                    ]
                  }
                ]
              }
            }

            # Verify that artists are joined with ", "
            search_service.expects(:search_by_artist_and_title)
              .with("Jay-Z, Kanye West", "Watch the Throne")
              .returns(search_response)

            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

            # Execute enrichment
            result = ItemsJsonEnricher.call(list: @list)

            # Assert successful result
            assert result[:success]

            # Verify both artists were captured
            enriched_album = @list.reload.items_json["albums"][0]
            assert_equal ["artist-1-id", "artist-2-id"], enriched_album["mb_artist_ids"]
            assert_equal ["Jay-Z", "Kanye West"], enriched_album["mb_artist_names"]
          end

          test "call skips entries without MusicBrainz matches and logs warnings" do
            # Mock MusicBrainz search responses - one success, one failure
            search_service = mock

            # First album - success
            search_service.expects(:search_by_artist_and_title)
              .with("The Smiths", "The Queen Is Dead")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "test-id",
                      "title" => "The Queen Is Dead",
                      "artist-credit" => [
                        {"artist" => {"id" => "artist-id", "name" => "The Smiths"}}
                      ]
                    }
                  ]
                }
              )

            # Second album - no match
            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Revolver")
              .returns(success: false, data: {"release-groups" => []})

            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

            # Expect warning log
            Rails.logger.expects(:warn)

            # Execute enrichment
            result = ItemsJsonEnricher.call(list: @list)

            # Assert partial success
            assert result[:success]
            assert_equal 1, result[:enriched_count]
            assert_equal 1, result[:skipped_count]
            assert_equal 2, result[:total_count]

            # Verify first album was enriched
            enriched_data = @list.reload.items_json["albums"]
            assert enriched_data[0].key?("mb_release_group_id")

            # Verify second album was NOT enriched (kept original data)
            refute enriched_data[1].key?("mb_release_group_id")
            assert_equal "Revolver", enriched_data[1]["title"]
          end

          test "call validates list is a Music::Albums::List" do
            books_list = lists(:books_list)

            error = assert_raises(ArgumentError) do
              ItemsJsonEnricher.call(list: books_list)
            end

            assert_equal "List must be a Music::Albums::List", error.message
          end

          test "call validates list has items_json populated" do
            empty_list = lists(:music_albums_list)
            empty_list.update!(items_json: nil)

            error = assert_raises(ArgumentError) do
              ItemsJsonEnricher.call(list: empty_list)
            end

            assert_equal "List must have items_json populated", error.message
          end

          test "call validates items_json contains albums array" do
            @list.update!(items_json: {"foo" => "bar"})

            error = assert_raises(ArgumentError) do
              ItemsJsonEnricher.call(list: @list)
            end

            assert_equal "List items_json must contain albums array", error.message
          end

          test "call handles search service errors gracefully and skips entries" do
            # Force an error by stubbing the search service to raise
            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).raises(StandardError.new("Test error"))

            # Expect warnings for skipped entries (not errors, since we handle gracefully)
            Rails.logger.expects(:warn).twice

            result = ItemsJsonEnricher.call(list: @list)

            # Should succeed overall but skip all entries due to errors
            assert result[:success]
            assert_equal 0, result[:enriched_count]
            assert_equal 2, result[:skipped_count]
            assert_equal 2, result[:total_count]
          end

          test "call handles empty release-groups array" do
            search_service = mock

            search_service.expects(:search_by_artist_and_title)
              .twice
              .returns(success: true, data: {"release-groups" => []})

            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

            Rails.logger.expects(:warn).twice

            result = ItemsJsonEnricher.call(list: @list)

            # Should skip all entries
            assert result[:success]
            assert_equal 0, result[:enriched_count]
            assert_equal 2, result[:skipped_count]
          end

          test "call handles missing artist-credit in response" do
            search_service = mock

            # Response without artist-credit
            search_response = {
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "test-id",
                    "title" => "The Queen Is Dead"
                    # No artist-credit field
                  }
                ]
              }
            }

            search_service.expects(:search_by_artist_and_title)
              .with("The Smiths", "The Queen Is Dead")
              .returns(search_response)

            search_service.expects(:search_by_artist_and_title)
              .with("The Beatles", "Revolver")
              .returns(success: false, data: {"release-groups" => []})

            ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

            result = ItemsJsonEnricher.call(list: @list)

            # Should still succeed but with empty artist arrays
            assert result[:success]
            assert_equal 1, result[:enriched_count]

            enriched_album = @list.reload.items_json["albums"][0]
            assert_equal [], enriched_album["mb_artist_ids"]
            assert_equal [], enriched_album["mb_artist_names"]
          end
        end
      end
    end
  end
end
