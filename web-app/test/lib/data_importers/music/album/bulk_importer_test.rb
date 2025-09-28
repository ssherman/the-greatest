# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      class BulkImporterTest < ActiveSupport::TestCase
        def setup
          @artist = music_artists(:pink_floyd)
          # Stub single album importer calls to prevent real imports during bulk tests
          Importer.stubs(:call).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "Mock Album"),
              provider_results: [],
              success: true
            )
          )
        end

        test "call successfully imports multiple albums when MusicBrainz returns data" do
          # Mock MusicBrainz API response with multiple albums
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "album-1-mbid",
                    "title" => "The Dark Side of the Moon"
                  },
                  {
                    "id" => "album-2-mbid",
                    "title" => "The Wall"
                  },
                  {
                    "id" => "album-3-mbid",
                    "title" => "Wish You Were Here"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          # Expect calls to single Album::Importer for each found album
          # Now includes artist and force_providers for proper enrichment
          Importer.expects(:call).with(
            release_group_musicbrainz_id: "album-1-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "The Dark Side of the Moon"),
              provider_results: [],
              success: true
            )
          )
          Importer.expects(:call).with(
            release_group_musicbrainz_id: "album-2-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "The Wall"),
              provider_results: [],
              success: true
            )
          )
          Importer.expects(:call).with(
            release_group_musicbrainz_id: "album-3-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "Wish You Were Here"),
              provider_results: [],
              success: true
            )
          )

          result = BulkImporter.call(artist: @artist)

          assert result.success?
          assert_instance_of BulkImporter::BulkImportResult, result
          assert_equal @artist, result.artist
          assert_equal 3, result.total_found
          assert_equal 3, result.successful_imports
          assert_equal 0, result.failed_imports
          assert_equal 3, result.albums.size
        end

        test "call uses primary_albums_only when specified" do
          search_service = mock
          search_service.expects(:search_primary_albums_only)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "primary-album-mbid",
                    "title" => "The Dark Side of the Moon"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          Importer.expects(:call).with(
            release_group_musicbrainz_id: "primary-album-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "The Dark Side of the Moon"),
              provider_results: [],
              success: true
            )
          )

          result = BulkImporter.call(artist: @artist, primary_albums_only: true)

          assert result.success?
          assert_equal 1, result.total_found
          assert_equal 1, result.successful_imports
        end

        test "call fails when artist has no MusicBrainz ID" do
          artist_without_mbid = music_artists(:roger_waters) # This artist has no MusicBrainz ID

          result = BulkImporter.call(artist: artist_without_mbid)

          refute result.success?
          assert_equal "Artist has no MusicBrainz ID", result.error
          assert_equal 0, result.total_found
          assert_equal 0, result.successful_imports
          assert_equal 0, result.failed_imports
          assert_empty result.albums
        end

        test "call fails when MusicBrainz returns no albums" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => []
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = BulkImporter.call(artist: @artist)

          refute result.success?
          assert_equal "No albums found in MusicBrainz", result.error
          assert_equal 0, result.total_found
          assert_equal 0, result.successful_imports
        end

        test "call handles MusicBrainz API failures gracefully" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: false,
              errors: ["Network timeout"]
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = BulkImporter.call(artist: @artist)

          refute result.success?
          assert_equal "No albums found in MusicBrainz", result.error
          assert_equal 0, result.total_found
        end

        test "call handles missing release-groups data gracefully" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {} # Missing "release-groups" key
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = BulkImporter.call(artist: @artist)

          refute result.success?
          assert_equal "No albums found in MusicBrainz", result.error
        end

        test "call continues processing when some album imports fail" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "success-album-mbid",
                    "title" => "Successful Album"
                  },
                  {
                    "id" => "fail-album-mbid",
                    "title" => "Failed Album"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          # First album succeeds
          Importer.expects(:call).with(
            release_group_musicbrainz_id: "success-album-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "Successful Album"),
              provider_results: [],
              success: true
            )
          )

          # Second album fails
          Importer.expects(:call).with(
            release_group_musicbrainz_id: "fail-album-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: nil,
              provider_results: [
                DataImporters::ProviderResult.failure(
                  provider: "TestProvider",
                  errors: ["Import failed"]
                )
              ],
              success: false
            )
          )

          result = BulkImporter.call(artist: @artist)

          assert result.success? # Overall success because at least one album succeeded
          assert_equal 2, result.total_found
          assert_equal 1, result.successful_imports
          assert_equal 1, result.failed_imports
          assert_equal 1, result.albums.size
          assert_equal "Successful Album", result.albums.first.title
        end

        test "call fails when all album imports fail" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "fail-album-mbid",
                    "title" => "Failed Album"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          Importer.expects(:call).with(
            release_group_musicbrainz_id: "fail-album-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: nil,
              provider_results: [
                DataImporters::ProviderResult.failure(
                  provider: "TestProvider",
                  errors: ["Import failed"]
                )
              ],
              success: false
            )
          )

          result = BulkImporter.call(artist: @artist)

          refute result.success?
          assert_equal 1, result.total_found
          assert_equal 0, result.successful_imports
          assert_equal 1, result.failed_imports
          assert_empty result.albums
        end

        test "call handles exceptions gracefully" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .raises(StandardError, "Connection failed")

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = BulkImporter.call(artist: @artist)

          refute result.success?
          assert_includes result.error, "Bulk import failed: Connection failed"
          assert_equal 0, result.total_found
          assert_equal 0, result.successful_imports
        end

        # Tests for BulkImportResult class
        test "BulkImportResult albums method returns only successful album items" do
          successful_result = DataImporters::ImportResult.new(
            item: ::Music::Album.new(title: "Success"),
            provider_results: [],
            success: true
          )

          failed_result = DataImporters::ImportResult.new(
            item: nil,
            provider_results: [],
            success: false
          )

          bulk_result = BulkImporter::BulkImportResult.new(
            artist: @artist,
            total_found: 2,
            successful_imports: 1,
            failed_imports: 1,
            import_results: [successful_result, failed_result],
            success: true
          )

          assert_equal 1, bulk_result.albums.size
          assert_equal "Success", bulk_result.albums.first.title
        end

        test "BulkImportResult albums method returns empty array when no successes" do
          failed_result = DataImporters::ImportResult.new(
            item: nil,
            provider_results: [],
            success: false
          )

          bulk_result = BulkImporter::BulkImportResult.new(
            artist: @artist,
            total_found: 1,
            successful_imports: 0,
            failed_imports: 1,
            import_results: [failed_result],
            success: false
          )

          assert_empty bulk_result.albums
        end

        test "class method delegates to instance method" do
          # This test ensures the class method properly creates an instance and calls it
          instance = mock
          instance.expects(:call).returns(
            BulkImporter::BulkImportResult.new(
              artist: @artist,
              total_found: 0,
              successful_imports: 0,
              failed_imports: 0,
              import_results: [],
              success: false,
              error: "Test error"
            )
          )

          BulkImporter.expects(:new).with(artist: @artist, primary_albums_only: false).returns(instance)

          result = BulkImporter.call(artist: @artist)

          refute result.success?
          assert_equal "Test error", result.error
        end

        test "class method passes primary_albums_only parameter correctly" do
          instance = mock
          instance.expects(:call).returns(
            BulkImporter::BulkImportResult.new(
              artist: @artist,
              total_found: 0,
              successful_imports: 0,
              failed_imports: 0,
              import_results: [],
              success: false
            )
          )

          BulkImporter.expects(:new).with(artist: @artist, primary_albums_only: true).returns(instance)

          BulkImporter.call(artist: @artist, primary_albums_only: true)
        end

        test "call passes artist and force_providers to ensure existing albums are enriched" do
          # This test verifies the fix for collaborative albums issue
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "collaborative-album-mbid",
                    "title" => "Collaborative Album"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          # The key assertion: Importer is called with artist and force_providers: true
          # This ensures existing albums get the new artist association and provider enrichment
          Importer.expects(:call).with(
            release_group_musicbrainz_id: "collaborative-album-mbid",
            artist: @artist,
            force_providers: true
          ).returns(
            DataImporters::ImportResult.new(
              item: ::Music::Album.new(title: "Collaborative Album"),
              provider_results: [],
              success: true
            )
          )

          result = BulkImporter.call(artist: @artist)

          assert result.success?
          assert_equal 1, result.total_found
          assert_equal 1, result.successful_imports
        end
      end
    end
  end
end
