# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Artist
      module Providers
        class MusicBrainzTest < ActiveSupport::TestCase
          def setup
            @provider = MusicBrainz.new
            @query = ImportQuery.new(name: "Pink Floyd")
            @artist = ::Music::Artist.new(name: "Pink Floyd")
          end

          test "populate returns success when artist data found" do
            # Mock successful search result with Pink Floyd data
            search_service = mock
            search_service.expects(:search_by_name).with("Pink Floyd").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                    "name" => "Pink Floyd",
                    "type" => "Group",
                    "country" => "GB",
                    "life-span" => {
                      "begin" => "1965",
                      "ended" => nil
                    },
                    "isnis" => ["0000000123456789"]
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@artist, query: @query)

            assert result.success?
            assert_equal "Pink Floyd", @artist.name
            assert_equal "band", @artist.kind
            assert_equal "GB", @artist.country
            assert_equal 1965, @artist.year_formed
            assert_nil @artist.year_disbanded

            # Check identifiers were built
            assert_equal 2, @artist.identifiers.length

            musicbrainz_identifier = @artist.identifiers.find { |id| id.identifier_type == "music_musicbrainz_artist_id" }
            assert_equal "83d91898-7763-47d7-b03b-b92132375c47", musicbrainz_identifier.value

            isni_identifier = @artist.identifiers.find { |id| id.identifier_type == "music_isni" }
            assert_equal "0000000123456789", isni_identifier.value

            expected_data_populated = [:name, :kind, :musicbrainz_id, :country, :life_span_data, :isni]
            assert_equal expected_data_populated, result.data_populated
          end

          test "populate handles person type with birth/death dates" do
            search_service = mock
            search_service.expects(:search_by_name).with("David Bowie").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "5441c29d-3602-4898-b1a1-b77fa23b8e50",
                    "name" => "David Bowie",
                    "type" => "Person",
                    "country" => "GB",
                    "life-span" => {
                      "begin" => "1947-01-08",
                      "ended" => "2016-01-10"
                    }
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(name: "David Bowie")
            artist = ::Music::Artist.new(name: "David Bowie")

            result = @provider.populate(artist, query: query)

            assert result.success?
            assert_equal "person", artist.kind
            assert_equal Date.parse("1947-01-08"), artist.born_on
            assert_equal 2016, artist.year_died
          end

          test "populate returns failure when search fails" do
            search_service = mock
            search_service.expects(:search_by_name).with("Pink Floyd").returns(
              success: false,
              errors: ["Network timeout"]
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@artist, query: @query)

            refute result.success?
            assert_equal ["Network timeout"], result.errors
          end

          test "populate returns failure when no artists found" do
            search_service = mock
            search_service.expects(:search_by_name).with("Unknown Artist").returns(
              success: true,
              data: {"artists" => []}
            )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(name: "Unknown Artist")
            result = @provider.populate(@artist, query: query)

            refute result.success?
            assert_equal ["No artists found"], result.errors
          end

          test "populate handles exceptions gracefully" do
            search_service = mock
            search_service.expects(:search_by_name).with("Pink Floyd").raises(StandardError, "Connection failed")

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@artist, query: @query)

            refute result.success?
            assert_includes result.errors.first, "MusicBrainz error: Connection failed"
          end

          test "populate handles partial data gracefully" do
            search_service = mock
            search_service.expects(:search_by_name).with("Minimal Artist").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "minimal-artist-id",
                    "name" => "Minimal Artist"
                    # No type, country, life-span, or isnis
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(name: "Minimal Artist")
            artist = ::Music::Artist.new(name: "Minimal Artist")

            result = @provider.populate(artist, query: query)

            assert result.success?
            assert_equal "Minimal Artist", artist.name
            assert_equal "person", artist.kind # Default
            assert_nil artist.country
            assert_nil artist.year_formed
            assert_equal 1, artist.identifiers.length # Just MusicBrainz ID
          end

          test "populate does not overwrite existing artist name when blank in search result" do
            search_service = mock
            search_service.expects(:search_by_name).with("Pink Floyd").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                    "name" => "", # Blank name in MusicBrainz result
                    "type" => "Group"
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            # Artist starts with a name
            @artist.name = "Pink Floyd"

            result = @provider.populate(@artist, query: @query)

            assert result.success?
            assert_equal "Pink Floyd", @artist.name # Should preserve original name
          end
        end
      end
    end
  end
end
