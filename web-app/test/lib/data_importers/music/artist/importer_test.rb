# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Artist
      class ImporterTest < ActiveSupport::TestCase
        def setup
          # Stub the AI description job since we're testing artist importing
          ::Music::ArtistDescriptionJob.stubs(:perform_async)
        end

        test "call with name creates and imports new artist" do
          # Mock MusicBrainz search to return no existing artist (called twice - finder + provider)
          search_service = mock
          search_service.expects(:search_by_name).with("New Artist").twice.returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => "new-artist-mbid",
                  "name" => "New Artist",
                  "type" => "Person",
                  "country" => "US"
                }
              ]
            }
          )

          # Stub the search service creation
          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "New Artist")

          assert result.success?
          assert_instance_of ::Music::Artist, result.item
          assert_equal "New Artist", result.item.name
          assert result.item.persisted?
          assert_equal "person", result.item.kind
          assert_equal "US", result.item.country
        end

        test "call returns existing artist when found" do
          # Use existing fixture artist
          existing_artist = music_artists(:pink_floyd)

          # Mock MusicBrainz search to return Pink Floyd's data
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").returns(
            success: true,
            data: {
              "artists" => [
                {"id" => "83d91898-7763-47d7-b03b-b92132375c47", "name" => "Pink Floyd"}
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Pink Floyd")

          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_artist, result.item
        end

        test "call fails when all providers fail" do
          # Mock MusicBrainz search to fail (called twice)
          search_service = mock
          search_service.expects(:search_by_name).with("Test Artist").twice.raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error").once

          result = Importer.call(name: "Test Artist")

          # Should fail because all providers failed:
          # - MusicBrainz fails (network error)
          # - AI Description fails (artist not persisted due to MusicBrainz failure)
          refute result.success?
          assert_equal "Test Artist", result.item.name
          refute result.item.persisted?
          assert_includes result.all_errors.join(", "), "Network error"
        end

        test "call succeeds when MusicBrainz finds no results but returns success" do
          search_service = mock
          search_service.expects(:search_by_name).with("Test Artist").twice.returns(
            success: true,
            data: {"artists" => []}
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Test Artist", country: "GB")

          # Should succeed because:
          # - MusicBrainz returns success (empty results, but success)
          # - Artist gets saved after MusicBrainz provider succeeds
          # - AI Description provider can then run successfully
          assert result.success?
          assert_equal "Test Artist", result.item.name
          assert result.item.persisted?
        end

        # Tests for new MusicBrainz ID import functionality
        test "call accepts musicbrainz_id parameter" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"

          search_service = mock
          search_service.expects(:lookup_by_mbid).with(mbid).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => mbid,
                  "name" => "Depeche Mode",
                  "type" => "Group",
                  "country" => "GB",
                  "genres" => [
                    {"name" => "electronic", "count" => 25},
                    {"name" => "synth-pop", "count" => 15}
                  ]
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(musicbrainz_id: mbid)

          assert result.success?
          assert result.item.persisted?
          assert_equal "Depeche Mode", result.item.name
          assert_equal "band", result.item.kind
          assert_equal "GB", result.item.country

          # Should have genre categories from lookup
          genre_names = result.item.categories.where(category_type: "genre").pluck(:name)
          assert_includes genre_names, "Electronic"
          assert_includes genre_names, "Synth-Pop"
        end

        test "call accepts both name and musicbrainz_id parameters" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"

          # Should call lookup_by_mbid since musicbrainz_id takes priority
          search_service = mock
          search_service.expects(:lookup_by_mbid).with(mbid).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => mbid,
                  "name" => "Depeche Mode",
                  "type" => "Group",
                  "country" => "GB"
                }
              ]
            }
          )
          # Should NOT call search_by_name since we have MBID
          search_service.expects(:search_by_name).never

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Some Name", musicbrainz_id: mbid)

          assert result.success?
          assert_equal "Depeche Mode", result.item.name
        end

        test "call finds existing artist by musicbrainz_id" do
          # Pink Floyd fixture has musicbrainz_id identifier
          existing_artist = music_artists(:pink_floyd)
          mbid = "83d91898-7763-47d7-b03b-b92132375c47"

          result = Importer.call(musicbrainz_id: mbid)

          # When existing artist found, returns ImportResult with the artist
          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_artist, result.item
          assert_equal "Pink Floyd", result.item.name
        end

        test "call validates musicbrainz_id format" do
          assert_raises(ArgumentError) do
            Importer.call(musicbrainz_id: "invalid-uuid")
          end
        end

        test "call requires either name or musicbrainz_id" do
          assert_raises(ArgumentError) do
            Importer.call(name: "", musicbrainz_id: "")
          end
        end

        test "call prioritizes musicbrainz_id over name in finder" do
          # This test ensures the finder uses MBID when both are provided
          existing_artist = music_artists(:pink_floyd)
          mbid = "83d91898-7763-47d7-b03b-b92132375c47"

          # Provide a different name than what's in the database
          result = Importer.call(name: "Wrong Name", musicbrainz_id: mbid)

          # When existing artist found, returns ImportResult with the artist
          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_artist, result.item
          assert_equal "Pink Floyd", result.item.name # Should find by MBID, not name
        end

        test "call with force_providers runs providers on existing items" do
          existing_artist = music_artists(:pink_floyd)

          # Mock MusicBrainz search for both finder and provider
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").twice.returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                  "name" => "Pink Floyd",
                  "type" => "Group",
                  "country" => "GB"
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Pink Floyd", force_providers: true)

          assert result.success?
          assert_equal existing_artist, result.item
          # Provider should have run and updated country
          assert_equal "GB", result.item.country
        end

        test "call creates new artist when musicbrainz_id not found locally" do
          unknown_mbid = "00000000-1111-2222-3333-444444444444"

          search_service = mock
          search_service.expects(:lookup_by_mbid).with(unknown_mbid).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => unknown_mbid,
                  "name" => "New Artist",
                  "type" => "Person"
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(musicbrainz_id: unknown_mbid)

          assert result.success?
          assert result.item.persisted?
          assert_equal "New Artist", result.item.name
          assert_equal "person", result.item.kind

          # Should create the identifier
          identifier = result.item.identifiers.find_by(identifier_type: :music_musicbrainz_artist_id)
          assert_equal unknown_mbid, identifier.value
        end

        test "force_providers does not create duplicate identifiers (fixed)" do
          # Create a new artist without any identifiers first
          new_artist = ::Music::Artist.create!(name: "Test Artist", kind: "person")

          # Mock MusicBrainz search for both finder and provider (2 calls per import = 4 total)
          search_service = mock
          search_service.expects(:search_by_name).with("Test Artist").times(4).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => "test-artist-mbid-123",
                  "name" => "Test Artist",
                  "type" => "Person",
                  "country" => "US",
                  "isnis" => ["0000000123456789"]
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          # Run once with force_providers
          result1 = Importer.call(name: "Test Artist", force_providers: true)
          assert result1.success?

          # Check identifiers after first run
          new_artist.reload
          first_run_identifier_count = new_artist.identifiers.count
          assert first_run_identifier_count > 0, "Should have created identifiers on first run"

          # Run again with force_providers - this should create duplicates (the bug)
          result2 = Importer.call(name: "Test Artist", force_providers: true)
          assert result2.success?

          # Check for duplicates
          new_artist.reload
          second_run_identifier_count = new_artist.identifiers.count

          # With the fix, second run should have same number of identifiers (no duplicates created)
          assert_equal first_run_identifier_count, second_run_identifier_count, "Should not create duplicate identifiers on second run"

          # Check for specific duplicates - should be exactly 1 of each
          musicbrainz_identifiers = new_artist.identifiers.where(identifier_type: :music_musicbrainz_artist_id)
          assert_equal 1, musicbrainz_identifiers.count, "Should have exactly one MusicBrainz identifier"

          isni_identifiers = new_artist.identifiers.where(identifier_type: :music_isni)
          assert_equal 1, isni_identifiers.count, "Should have exactly one ISNI identifier"
        end

        test "force_providers persists associations even when no attributes change" do
          # Create an artist that already has the same name that MusicBrainz will return
          existing_artist = ::Music::Artist.create!(name: "Test Band", kind: "band")
          original_identifier_count = existing_artist.identifiers.count

          # Mock MusicBrainz to return data that won't change attributes but will add identifiers
          search_service = mock
          search_service.expects(:search_by_name).with("Test Band").twice.returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => "test-band-mbid-456",
                  "name" => "Test Band", # Same name - no attribute change
                  "type" => "Group",     # Will map to "band" - no change
                  "isnis" => ["0000000123456789"] # This will add a new identifier
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          # Run with force_providers to add identifiers
          result = Importer.call(name: "Test Band", force_providers: true)

          assert result.success?
          assert_equal existing_artist, result.item

          # Even though no attributes changed, the new identifiers should be persisted
          existing_artist.reload
          final_identifier_count = existing_artist.identifiers.count

          assert final_identifier_count > original_identifier_count,
            "Should have persisted new identifiers even when no attributes changed"

          # Verify the specific identifiers were saved
          musicbrainz_id = existing_artist.identifiers.find_by(identifier_type: :music_musicbrainz_artist_id)
          assert_not_nil musicbrainz_id, "MusicBrainz identifier should be persisted"
          assert_equal "test-band-mbid-456", musicbrainz_id.value

          isni_id = existing_artist.identifiers.find_by(identifier_type: :music_isni)
          assert_not_nil isni_id, "ISNI identifier should be persisted"
          assert_equal "0000000123456789", isni_id.value
        end
      end
    end
  end
end
