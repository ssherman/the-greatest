# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Release
      module Providers
        class MusicBrainzTest < ActiveSupport::TestCase
          def setup
            @album = music_albums(:dark_side_of_the_moon)
            @query = ImportQuery.new(album: @album)
            @provider = MusicBrainz.new
          end

          test "populate fails when album has no release group MBID" do
            album_without_mbid = music_albums(:animals)
            query = ImportQuery.new(album: album_without_mbid)

            result = @provider.populate(nil, query: query)

            refute result.success?
            assert_includes result.errors, "No release group MBID found for album"
          end

          test "populate fails when MusicBrainz search returns no releases" do
            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
              .returns({data: {"releases" => []}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            result = @provider.populate(nil, query: @query)

            refute result.success?
            assert_includes result.errors, "No releases found in MusicBrainz"
          end

          test "populate creates multiple releases from MusicBrainz data" do
            musicbrainz_releases = [
              {
                "id" => "mb-release-1",
                "title" => "The Dark Side of the Moon",
                "date" => "1973-03-01",
                "country" => "GB",
                "status" => "Official",
                "media" => [{"format" => "CD"}],
                "label-info" => [{"label" => {"name" => "Harvest"}}],
                "asin" => "B000001234",
                "barcode" => "123456789",
                "packaging" => "Jewel Case"
              },
              {
                "id" => "mb-release-2",
                "title" => "The Dark Side of the Moon - Remaster",
                "date" => "2011-09-26",
                "country" => "US",
                "status" => "Official",
                "media" => [{"format" => "12\" Vinyl"}],
                "label-info" => [{"label" => {"name" => "EMI"}}]
              }
            ]

            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
              .returns({data: {"releases" => musicbrainz_releases}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            initial_count = @album.releases.count

            result = @provider.populate(nil, query: @query)

            assert result.success?
            assert_equal [:releases_created, :songs_created, :tracks_created], result.data_populated
            assert_equal initial_count + 2, @album.releases.count

            # Check first release
            release1 = @album.releases.find_by(release_name: "The Dark Side of the Moon")
            assert_not_nil release1
            assert_equal Date.parse("1973-03-01"), release1.release_date
            assert_equal "GB", release1.country
            assert_equal "official", release1.status
            assert_equal "cd", release1.format
            assert_equal ["Harvest"], release1.labels
            assert_equal "B000001234", release1.metadata["asin"]
            assert_equal "123456789", release1.metadata["barcode"]

            # Check identifiers
            mbid_identifier = release1.identifiers.find_by(identifier_type: :music_musicbrainz_release_id)
            assert_equal "mb-release-1", mbid_identifier.value

            asin_identifier = release1.identifiers.find_by(identifier_type: :music_asin)
            assert_equal "B000001234", asin_identifier.value

            # Check second release
            release2 = @album.releases.find_by(release_name: "The Dark Side of the Moon - Remaster")
            assert_not_nil release2
            assert_equal "vinyl", release2.format
            assert_equal ["EMI"], release2.labels
          end

          test "populate skips existing releases" do
            # Create existing release with MusicBrainz ID
            existing_release = @album.releases.create!(
              format: :cd,
              status: :official,
              release_name: "Existing Release"
            )
            existing_release.identifiers.create!(
              identifier_type: :music_musicbrainz_release_id,
              value: "mb-release-1"
            )

            musicbrainz_releases = [
              {
                "id" => "mb-release-1",
                "title" => "The Dark Side of the Moon",
                "date" => "1973-03-01",
                "country" => "GB",
                "status" => "Official",
                "media" => [{"format" => "CD"}]
              },
              {
                "id" => "mb-release-2",
                "title" => "New Release",
                "date" => "2011-09-26",
                "country" => "US",
                "status" => "Official",
                "media" => [{"format" => "Vinyl"}]
              }
            ]

            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
              .returns({data: {"releases" => musicbrainz_releases}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            initial_count = @album.releases.count

            result = @provider.populate(nil, query: @query)

            assert result.success?
            # Should only create one new release (skipping the existing one)
            assert_equal initial_count + 1, @album.releases.count
            assert @album.releases.exists?(release_name: "New Release")
          end

          test "populate handles format parsing correctly" do
            test_cases = [
              {"format" => "CD", "expected" => "cd"},
              {"format" => "12\" Vinyl", "expected" => "vinyl"},
              {"format" => "Digital Media", "expected" => "digital"},
              {"format" => "Cassette", "expected" => "cassette"},
              {"format" => "DVD", "expected" => "other"},
              {"format" => "SACD", "expected" => "other"},
              {"format" => "", "expected" => "other"}
            ]

            test_cases.each_with_index do |test_case, index|
              musicbrainz_releases = [{
                "id" => "mb-release-#{index}",
                "title" => "Test Release #{index}",
                "status" => "Official",
                "media" => [{"format" => test_case["format"]}]
              }]

              search_service = mock
              search_service.expects(:search_by_release_group_mbid_with_recordings)
                .returns({data: {"releases" => musicbrainz_releases}})

              ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

              @provider.populate(nil, query: @query)

              release = @album.releases.find_by(release_name: "Test Release #{index}")
              assert_equal test_case["expected"], release.format,
                "Format '#{test_case["format"]}' should map to '#{test_case["expected"]}'"
            end
          end

          test "populate handles status parsing correctly" do
            test_cases = [
              {"status" => "Official", "expected" => "official"},
              {"status" => "Promotion", "expected" => "promotion"},
              {"status" => "Bootleg", "expected" => "bootleg"},
              {"status" => "Pseudo-Release", "expected" => "pseudo_release"},
              {"status" => "Withdrawn", "expected" => "withdrawn"},
              {"status" => "Expunged", "expected" => "expunged"},
              {"status" => "Cancelled", "expected" => "cancelled"},
              {"status" => "", "expected" => "official"},
              {"status" => nil, "expected" => "official"}
            ]

            test_cases.each_with_index do |test_case, index|
              musicbrainz_releases = [{
                "id" => "mb-status-#{index}",
                "title" => "Status Test #{index}",
                "status" => test_case["status"],
                "media" => [{"format" => "CD"}]
              }]

              search_service = mock
              search_service.expects(:search_by_release_group_mbid_with_recordings)
                .returns({data: {"releases" => musicbrainz_releases}})

              ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

              @provider.populate(nil, query: @query)

              release = @album.releases.find_by(release_name: "Status Test #{index}")
              assert_equal test_case["expected"], release.status,
                "Status '#{test_case["status"]}' should map to '#{test_case["expected"]}'"
            end
          end

          test "populate handles date parsing gracefully" do
            musicbrainz_releases = [
              {
                "id" => "date-test-1",
                "title" => "Valid Date",
                "date" => "1973-03-01",
                "media" => [{"format" => "CD"}]
              },
              {
                "id" => "date-test-2",
                "title" => "Invalid Date",
                "date" => "invalid-date",
                "media" => [{"format" => "CD"}]
              },
              {
                "id" => "date-test-3",
                "title" => "No Date",
                "media" => [{"format" => "CD"}]
              }
            ]

            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .returns({data: {"releases" => musicbrainz_releases}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            result = @provider.populate(nil, query: @query)

            assert result.success?

            valid_date_release = @album.releases.find_by(release_name: "Valid Date")
            assert_equal Date.parse("1973-03-01"), valid_date_release.release_date

            invalid_date_release = @album.releases.find_by(release_name: "Invalid Date")
            assert_nil invalid_date_release.release_date

            no_date_release = @album.releases.find_by(release_name: "No Date")
            assert_nil no_date_release.release_date
          end

          test "populate handles errors gracefully" do
            # Mock a release that will fail to save
            ::Music::Release.any_instance.stubs(:save).returns(false)
            ::Music::Release.any_instance.stubs(:errors).returns(
              stub(full_messages: ["Title can't be blank"])
            )

            musicbrainz_releases = [{
              "id" => "error-test",
              "title" => "Error Test",
              "media" => [{"format" => "CD"}]
            }]

            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .returns({data: {"releases" => musicbrainz_releases}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            result = @provider.populate(nil, query: @query)

            refute result.success?
            assert_includes result.errors.join(", "), "Failed to save release: Title can't be blank"
          end

          test "populate builds metadata correctly" do
            musicbrainz_releases = [{
              "id" => "metadata-test",
              "title" => "Metadata Test",
              "asin" => "B000123456",
              "barcode" => "123456789012",
              "packaging" => "Digipak",
              "media" => [{"format" => "CD", "disc-count" => 1}],
              "text-representation" => {"language" => "eng", "script" => "Latn"},
              "release-events" => [{"date" => "1973-03-01", "area" => {"name" => "United Kingdom"}}]
            }]

            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .returns({data: {"releases" => musicbrainz_releases}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            @provider.populate(nil, query: @query)

            release = @album.releases.find_by(release_name: "Metadata Test")
            metadata = release.metadata

            assert_equal "B000123456", metadata["asin"]
            assert_equal "123456789012", metadata["barcode"]
            assert_equal "Digipak", metadata["packaging"]
            assert_not_nil metadata["media"]
            assert_not_nil metadata["text_representation"]
            assert_not_nil metadata["release_events"]
          end

          test "parse_labels deduplicates duplicate label names" do
            label_info_with_duplicates = [
              {"label" => {"name" => "EMI"}},
              {"label" => {"name" => "EMI"}},
              {"label" => {"name" => "Harvest"}},
              {"label" => {"name" => "EMI"}},
              {"label" => {"name" => "Harvest"}}
            ]

            labels = @provider.send(:parse_labels, label_info_with_duplicates)

            assert_equal ["EMI", "Harvest"], labels
            assert_equal 2, labels.length
          end

          test "populate creates songs with artist associations via Song::Importer" do
            recording_id = "test-recording-123"

            musicbrainz_releases = [{
              "id" => "release-with-tracks",
              "title" => "Test Album",
              "status" => "Official",
              "media" => [{
                "format" => "CD",
                "tracks" => [{
                  "id" => "track-1",
                  "position" => 1,
                  "recording" => {
                    "id" => recording_id,
                    "title" => "Test Song"
                  }
                }]
              }]
            }]

            search_service = mock
            search_service.expects(:search_by_release_group_mbid_with_recordings)
              .returns({data: {"releases" => musicbrainz_releases}})

            ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

            mock
            song_import_result = mock
            song = ::Music::Song.new(
              title: "Test Song",
              id: 999
            )
            song.stubs(:persisted?).returns(true)
            song_import_result.stubs(:success?).returns(true)
            song_import_result.stubs(:item).returns(song)

            DataImporters::Music::Song::Importer.expects(:call)
              .with(musicbrainz_recording_id: recording_id)
              .returns(song_import_result)

            result = @provider.populate(nil, query: @query)

            assert result.success?
          end
        end
      end
    end
  end
end
