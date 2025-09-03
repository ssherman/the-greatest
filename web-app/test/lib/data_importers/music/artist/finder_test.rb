# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Artist
      class FinderTest < ActiveSupport::TestCase
        def setup
          @finder = Finder.new
          @query = ImportQuery.new(name: "Pink Floyd")
        end

        test "call returns existing artist when found by MusicBrainz search" do
          # Mock the search service to return Pink Floyd's data
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").returns(
            success: true,
            data: {
              "artists" => [
                {"id" => "83d91898-7763-47d7-b03b-b92132375c47", "name" => "Pink Floyd"}
              ]
            }
          )

          @finder.stubs(:search_service).returns(search_service)

          result = @finder.call(query: @query)

          assert_equal music_artists(:pink_floyd), result
        end

        test "call returns existing artist when found by exact name match" do
          # Mock search service to return no results, fall back to name matching
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").returns(
            success: true,
            data: {"artists" => []}
          )

          @finder.stubs(:search_service).returns(search_service)

          result = @finder.call(query: @query)

          assert_equal music_artists(:pink_floyd), result
        end

        test "call returns nil when no artist found by any method" do
          # Mock search service to return no results
          search_service = mock
          search_service.expects(:search_by_name).with("Unknown Artist").returns(
            success: true,
            data: {"artists" => []}
          )

          @finder.stubs(:search_service).returns(search_service)

          unknown_query = ImportQuery.new(name: "Unknown Artist")
          result = @finder.call(query: unknown_query)

          assert_nil result
        end

        test "call handles MusicBrainz search errors gracefully" do
          # Mock search service to raise an exception
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").raises(StandardError, "Network error")

          @finder.stubs(:search_service).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error")

          # Should still fall back to name matching
          result = @finder.call(query: @query)

          assert_equal music_artists(:pink_floyd), result
        end

        test "call returns nil for unknown artist when MusicBrainz fails" do
          # Mock search service to raise an exception
          search_service = mock
          search_service.expects(:search_by_name).with("Unknown Artist").raises(StandardError, "Network error")

          @finder.stubs(:search_service).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error")

          unknown_query = ImportQuery.new(name: "Unknown Artist")
          result = @finder.call(query: unknown_query)

          assert_nil result
        end

        test "call prioritizes MusicBrainz ID over name matching" do
          # Mock search service to return David Bowie's data when searching for "Pink Floyd"
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").returns(
            success: true,
            data: {
              "artists" => [
                {"id" => "5441c29d-3602-4898-b1a1-b77fa23b8e50", "name" => "David Bowie"}
              ]
            }
          )

          @finder.stubs(:search_service).returns(search_service)

          # Should return David Bowie (found by MBID) not Pink Floyd (found by name)
          result = @finder.call(query: @query)

          assert_equal music_artists(:david_bowie), result
        end

        # Tests for new MusicBrainz ID lookup functionality
        test "call uses direct MBID lookup when musicbrainz_id is provided" do
          mbid = "83d91898-7763-47d7-b03b-b92132375c47"
          query = ImportQuery.new(musicbrainz_id: mbid)

          # Should NOT call the search service when we have an MBID
          search_service = mock
          search_service.expects(:search_by_name).never
          @finder.stubs(:search_service).returns(search_service)

          result = @finder.call(query: query)

          # Should find Pink Floyd by MBID identifier
          assert_equal music_artists(:pink_floyd), result
        end

        test "call returns nil when musicbrainz_id is provided but no artist found with that MBID" do
          unknown_mbid = "00000000-0000-0000-0000-000000000000"
          query = ImportQuery.new(musicbrainz_id: unknown_mbid)

          result = @finder.call(query: query)

          assert_nil result
        end

        test "call prioritizes musicbrainz_id over name when both are provided" do
          mbid = "83d91898-7763-47d7-b03b-b92132375c47"
          query = ImportQuery.new(name: "Some Other Name", musicbrainz_id: mbid)

          # Should NOT call the search service when we have an MBID
          search_service = mock
          search_service.expects(:search_by_name).never
          @finder.stubs(:search_service).returns(search_service)

          result = @finder.call(query: query)

          # Should find Pink Floyd by MBID, ignoring the name
          assert_equal music_artists(:pink_floyd), result
        end

        test "call falls back to name-based search when musicbrainz_id is blank" do
          query = ImportQuery.new(name: "Pink Floyd", musicbrainz_id: "")

          # Should call the search service for name-based search
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").returns(
            success: true,
            data: {
              "artists" => [
                {"id" => "83d91898-7763-47d7-b03b-b92132375c47", "name" => "Pink Floyd"}
              ]
            }
          )
          @finder.stubs(:search_service).returns(search_service)

          result = @finder.call(query: query)

          assert_equal music_artists(:pink_floyd), result
        end
      end
    end
  end
end
