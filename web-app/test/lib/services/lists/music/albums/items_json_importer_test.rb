require "test_helper"

module Services
  module Lists
    module Music
      module Albums
        class ItemsJsonImporterTest < ActiveSupport::TestCase
          def setup
            @list = lists(:music_albums_list_for_import)
          end

          test "validates list is required" do
            error = assert_raises(ArgumentError) do
              ItemsJsonImporter.call(list: nil)
            end

            assert_equal "List is required", error.message
          end

          test "validates list has items_json" do
            @list.update!(items_json: nil)

            error = assert_raises(ArgumentError) do
              ItemsJsonImporter.call(list: @list)
            end

            assert_equal "List must have items_json", error.message
          end

          test "validates items_json has albums array" do
            @list.update!(items_json: {"foo" => "bar"})

            error = assert_raises(ArgumentError) do
              ItemsJsonImporter.call(list: @list)
            end

            assert_equal "items_json must have albums array", error.message
          end

          test "validates albums array is not empty" do
            @list.update!(items_json: {"albums" => []})

            error = assert_raises(ArgumentError) do
              ItemsJsonImporter.call(list: @list)
            end

            assert_equal "items_json albums array is empty", error.message
          end

          test "skips albums flagged as ai_match_invalid" do
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Bad Match",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-id",
                    "ai_match_invalid" => true
                  }
                ]
              }
            )

            result = ItemsJsonImporter.call(list: @list)

            assert result.success
            assert_equal 0, result.imported_count
            assert_equal 0, result.created_directly_count
            assert_equal 1, result.skipped_count
            assert_equal 0, result.error_count
          end

          test "skips albums without enrichment data" do
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Not Enriched",
                    "artists" => ["Test Artist"]
                  }
                ]
              }
            )

            result = ItemsJsonImporter.call(list: @list)

            assert result.success
            assert_equal 0, result.imported_count
            assert_equal 0, result.created_directly_count
            assert_equal 1, result.skipped_count
            assert_equal 0, result.error_count
          end

          test "creates list_item for album that already exists in database" do
            existing_album = music_albums(:dark_side_of_the_moon)

            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "The Dark Side of the Moon",
                    "artists" => ["Pink Floyd"],
                    "album_id" => existing_album.id,
                    "album_name" => existing_album.title
                  }
                ]
              }
            )

            assert_difference "ListItem.count", 1 do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 0, result.imported_count
              assert_equal 1, result.created_directly_count
              assert_equal 0, result.skipped_count
              assert_equal 0, result.error_count
            end

            list_item = @list.list_items.last
            assert_equal existing_album, list_item.listable
            assert_equal 1, list_item.position
            assert list_item.verified
          end

          test "imports album when only mb_release_group_id is present" do
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Test Album",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-mb-id",
                    "mb_release_group_name" => "Test Album"
                  }
                ]
              }
            )

            mock_result = stub(success?: true, item: music_albums(:nevermind))
            DataImporters::Music::Album::Importer.expects(:call)
              .with(release_group_musicbrainz_id: "test-mb-id")
              .returns(mock_result)

            assert_difference "ListItem.count", 1 do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 1, result.imported_count
              assert_equal 0, result.created_directly_count
              assert_equal 0, result.skipped_count
              assert_equal 0, result.error_count
            end

            list_item = @list.list_items.last
            assert_equal music_albums(:nevermind), list_item.listable
            assert_equal 1, list_item.position
            assert list_item.verified
          end

          test "prevents duplicate list_items" do
            existing_album = music_albums(:dark_side_of_the_moon)
            list_items(:music_albums_item).update!(list: @list, listable: existing_album)

            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 5,
                    "title" => "The Dark Side of the Moon",
                    "artists" => ["Pink Floyd"],
                    "album_id" => existing_album.id,
                    "album_name" => existing_album.title
                  }
                ]
              }
            )

            assert_no_difference "ListItem.count" do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 0, result.imported_count
              assert_equal 0, result.created_directly_count
              assert_equal 1, result.skipped_count
              assert_equal 0, result.error_count
            end
          end

          test "handles album import failures gracefully" do
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Test Album",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-mb-id"
                  }
                ]
              }
            )

            mock_result = stub(success?: false, all_errors: ["Import failed"])
            DataImporters::Music::Album::Importer.expects(:call)
              .with(release_group_musicbrainz_id: "test-mb-id")
              .returns(mock_result)

            assert_no_difference "ListItem.count" do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 0, result.imported_count
              assert_equal 0, result.created_directly_count
              assert_equal 0, result.skipped_count
              assert_equal 1, result.error_count
              assert_includes result.data[:error_messages], "Failed to load/import: Test Album"
            end
          end

          test "handles album_id that doesn't exist and falls back to import" do
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Test Album",
                    "artists" => ["Test Artist"],
                    "album_id" => 999999,
                    "album_name" => "Test Album",
                    "mb_release_group_id" => "test-mb-id"
                  }
                ]
              }
            )

            mock_result = stub(success?: true, item: music_albums(:nevermind))
            DataImporters::Music::Album::Importer.expects(:call)
              .with(release_group_musicbrainz_id: "test-mb-id")
              .returns(mock_result)

            assert_difference "ListItem.count", 1 do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 1, result.imported_count
              assert_equal 0, result.created_directly_count
              assert_equal 0, result.skipped_count
              assert_equal 0, result.error_count
            end
          end

          test "processes multiple albums with mixed results" do
            existing_album = music_albums(:dark_side_of_the_moon)

            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Existing Album",
                    "artists" => ["Pink Floyd"],
                    "album_id" => existing_album.id,
                    "album_name" => existing_album.title
                  },
                  {
                    "rank" => 2,
                    "title" => "New Album",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-mb-id"
                  },
                  {
                    "rank" => 3,
                    "title" => "Skipped Album",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-mb-id-2",
                    "ai_match_invalid" => true
                  }
                ]
              }
            )

            mock_result = stub(success?: true, item: music_albums(:nevermind))
            DataImporters::Music::Album::Importer.expects(:call)
              .with(release_group_musicbrainz_id: "test-mb-id")
              .returns(mock_result)

            assert_difference "ListItem.count", 2 do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 1, result.imported_count
              assert_equal 1, result.created_directly_count
              assert_equal 1, result.skipped_count
              assert_equal 0, result.error_count
              assert_equal 3, result.data[:total_albums]
            end
          end

          test "handles exceptions during processing gracefully" do
            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Test Album",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-mb-id"
                  },
                  {
                    "rank" => 2,
                    "title" => "Another Album",
                    "artists" => ["Test Artist"],
                    "mb_release_group_id" => "test-mb-id-2"
                  }
                ]
              }
            )

            mock_result = stub(success?: true, item: music_albums(:nevermind))
            DataImporters::Music::Album::Importer.expects(:call)
              .with(release_group_musicbrainz_id: "test-mb-id")
              .raises(StandardError.new("Test error"))

            DataImporters::Music::Album::Importer.expects(:call)
              .with(release_group_musicbrainz_id: "test-mb-id-2")
              .returns(mock_result)

            assert_difference "ListItem.count", 1 do
              result = ItemsJsonImporter.call(list: @list)

              assert result.success
              assert_equal 1, result.imported_count
              assert_equal 0, result.created_directly_count
              assert_equal 0, result.skipped_count
              assert_equal 1, result.error_count
              assert_equal 1, result.data[:error_messages].length
            end
          end

          test "returns proper result structure" do
            existing_album = music_albums(:dark_side_of_the_moon)

            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Test Album",
                    "artists" => ["Pink Floyd"],
                    "album_id" => existing_album.id,
                    "album_name" => existing_album.title
                  }
                ]
              }
            )

            result = ItemsJsonImporter.call(list: @list)

            assert_instance_of ItemsJsonImporter::Result, result
            assert result.success
            assert_kind_of String, result.message
            assert_kind_of Hash, result.data
            assert_equal 1, result.data[:total_albums]
            assert_equal 0, result.data[:imported]
            assert_equal 1, result.data[:created_directly]
            assert_equal 0, result.data[:skipped]
            assert_equal 0, result.data[:errors]
            assert_kind_of Array, result.data[:error_messages]
          end

          test "sets verified field to true on created list_items" do
            existing_album = music_albums(:dark_side_of_the_moon)

            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 1,
                    "title" => "Test Album",
                    "artists" => ["Pink Floyd"],
                    "album_id" => existing_album.id,
                    "album_name" => existing_album.title
                  }
                ]
              }
            )

            result = ItemsJsonImporter.call(list: @list)

            assert result.success
            list_item = @list.list_items.last
            assert list_item.verified, "List item should be marked as verified"
          end

          test "uses rank as position for list_items" do
            existing_album = music_albums(:dark_side_of_the_moon)

            @list.update!(
              items_json: {
                "albums" => [
                  {
                    "rank" => 42,
                    "title" => "Test Album",
                    "artists" => ["Pink Floyd"],
                    "album_id" => existing_album.id,
                    "album_name" => existing_album.title
                  }
                ]
              }
            )

            result = ItemsJsonImporter.call(list: @list)

            assert result.success
            list_item = @list.list_items.last
            assert_equal 42, list_item.position
          end
        end
      end
    end
  end
end
