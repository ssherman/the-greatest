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
                      "end" => "2016-01-10",
                      "ended" => true
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

          test "populate returns success when no artists found" do
            search_service = mock
            search_service.expects(:search_by_name).with("Unknown Artist").returns(
              success: true,
              data: {"artists" => []}
            )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(name: "Unknown Artist")
            result = @provider.populate(@artist, query: query)

            assert result.success?
            assert_equal [], result.data_populated
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

          # NEW TESTS BELOW
          test "populate creates top 5 genre categories and location categories for artists" do
            persisted_artist = music_artists(:pink_floyd)

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
                    "tags" => [
                      {"count" => 25, "name" => "electronic"},
                      {"count" => 0, "name" => "downtempo"},
                      {"count" => 19, "name" => "synth-pop"},
                      {"count" => 9, "name" => "alternative rock"},
                      {"count" => 8, "name" => "british"},
                      {"count" => 6, "name" => "dark wave"},
                      {"count" => 1, "name" => "psychedelic rock"}
                    ],
                    "area" => {"name" => "United Kingdom", "type" => "Country"},
                    "begin-area" => {"name" => "London", "type" => "City"}
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(persisted_artist, query: @query)
            assert result.success?

            persisted_artist.reload

            category_names = persisted_artist.categories.pluck(:name)
            # Top 5 by count excluding zero, normalized
            assert_includes category_names, "Electronic"
            assert_includes category_names, "Synth-Pop"
            assert_includes category_names, "Alternative Rock"
            assert_includes category_names, "British"
            assert_includes category_names, "Dark Wave"
            refute_includes category_names, "Downtempo"

            # Location categories present on artist
            location_names = persisted_artist.categories.where(category_type: "location").pluck(:name)
            assert_includes location_names, "United Kingdom"
            assert_includes location_names, "London"

            # Metadata on a sample category
            genre_cat = ::Music::Category.find_by(name: "Electronic")
            assert_equal "genre", genre_cat.category_type
            assert_equal "musicbrainz", genre_cat.import_source

            loc_cat = ::Music::Category.find_by(name: "United Kingdom")
            assert_equal "location", loc_cat.category_type
            assert_equal "musicbrainz", loc_cat.import_source
          end

          # Tests for new MusicBrainz ID lookup functionality
          test "populate uses lookup API when musicbrainz_id is provided" do
            mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"
            query = ImportQuery.new(musicbrainz_id: mbid)
            artist = ::Music::Artist.new # Fresh artist without preset name

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
                    "life-span" => {"begin" => "1980-03", "end" => nil, "ended" => false}
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(artist, query: query)

            assert result.success?
            assert_equal "Depeche Mode", artist.name
            assert_equal "band", artist.kind
            assert_equal "GB", artist.country
            assert_equal 1980, artist.year_formed
          end

          test "populate uses search API when name is provided" do
            query = ImportQuery.new(name: "Pink Floyd")

            search_service = mock
            search_service.expects(:search_by_name).with("Pink Floyd").returns(
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

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@artist, query: query)

            assert result.success?
            assert_equal "Pink Floyd", @artist.name
          end

          test "populate processes both genres and tags for categories" do
            persisted_artist = music_artists(:pink_floyd)
            query = ImportQuery.new(name: "Test Artist")

            search_service = mock
            search_service.expects(:search_by_name).with("Test Artist").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "test-mbid",
                    "name" => "Test Artist",
                    "type" => "Group",
                    "genres" => [
                      {"name" => "electronic", "count" => 25},
                      {"name" => "synth-pop", "count" => 15},
                      {"name" => "new wave", "count" => 12}
                    ],
                    "tags" => [
                      {"name" => "alternative dance", "count" => 8},
                      {"name" => "dark wave", "count" => 6},
                      {"name" => "minimal techno", "count" => 4}
                    ]
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(persisted_artist, query: query)

            assert result.success?

            # Should create categories from both genres and tags
            genre_names = persisted_artist.categories.where(category_type: "genre").pluck(:name)

            # From genres field
            assert_includes genre_names, "Electronic"
            assert_includes genre_names, "Synth-Pop"
            assert_includes genre_names, "New Wave"

            # From tags field
            assert_includes genre_names, "Alternative Dance"
            assert_includes genre_names, "Dark Wave"
            assert_includes genre_names, "Minimal Techno"
          end

          test "populate extracts top 5 genres from combined tags and genres" do
            persisted_artist = music_artists(:pink_floyd)
            query = ImportQuery.new(name: "Test Artist")

            search_service = mock
            search_service.expects(:search_by_name).with("Test Artist").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "test-mbid",
                    "name" => "Test Artist",
                    "type" => "Group",
                    "genres" => [
                      {"name" => "genre1", "count" => 30},
                      {"name" => "genre2", "count" => 25},
                      {"name" => "genre3", "count" => 20}
                    ],
                    "tags" => [
                      {"name" => "tag1", "count" => 15},
                      {"name" => "tag2", "count" => 10},
                      {"name" => "tag3", "count" => 5},
                      {"name" => "tag4", "count" => 3}
                    ]
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(persisted_artist, query: query)

            assert result.success?

            # Should create categories but respect the top 5 limit per field
            genre_names = persisted_artist.categories.where(category_type: "genre").pluck(:name)

            # All genres should be included (3 total)
            assert_includes genre_names, "Genre1"
            assert_includes genre_names, "Genre2"
            assert_includes genre_names, "Genre3"

            # Top 5 tags should be included (only 4 exist)
            assert_includes genre_names, "Tag1"
            assert_includes genre_names, "Tag2"
            assert_includes genre_names, "Tag3"
            assert_includes genre_names, "Tag4"
          end

          test "populate handles empty genres and tags gracefully" do
            query = ImportQuery.new(name: "Test Artist")
            artist = ::Music::Artist.new # Fresh artist without preset name

            search_service = mock
            search_service.expects(:search_by_name).with("Test Artist").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "test-mbid",
                    "name" => "Test Artist",
                    "type" => "Group",
                    "genres" => [],
                    "tags" => []
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(artist, query: query)

            assert result.success?
            assert_equal "Test Artist", artist.name
            # No genre categories should be created
            assert_equal 0, artist.categories.where(category_type: "genre").count
          end

          test "populate handles missing genres and tags fields gracefully" do
            query = ImportQuery.new(name: "Test Artist")
            artist = ::Music::Artist.new # Fresh artist without preset name

            search_service = mock
            search_service.expects(:search_by_name).with("Test Artist").returns(
              success: true,
              data: {
                "artists" => [
                  {
                    "id" => "test-mbid",
                    "name" => "Test Artist",
                    "type" => "Group"
                    # No genres or tags fields
                  }
                ]
              }
            )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(artist, query: query)

            assert result.success?
            assert_equal "Test Artist", artist.name
            # No genre categories should be created
            assert_equal 0, artist.categories.where(category_type: "genre").count
          end
        end
      end
    end
  end
end
