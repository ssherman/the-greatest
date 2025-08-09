# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      class ImporterTest < ActiveSupport::TestCase
        def setup
          @artist = music_artists(:pink_floyd)
        end

        test "call with artist and title creates and imports new album" do
          # Mock MusicBrainz search to return no existing album (called twice - finder + provider)
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
            .twice
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "the-wall-mbid",
                    "title" => "The Wall",
                    "first-release-date" => "1979-11-30"
                  }
                ]
              }
            )

          # Stub the search service creation
          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist, title: "The Wall")

          assert result.success?
          assert_instance_of ::Music::Album, result.item
          assert_equal "The Wall", result.item.title
          assert_equal @artist, result.item.primary_artist
          assert result.item.persisted?
          assert_equal 1979, result.item.release_year
        end

        test "call returns existing album when found" do
          # Use existing fixture album
          existing_album = music_albums(:dark_side_of_the_moon)

          # Mock the finder to return existing album
          finder = mock
          finder.expects(:call).returns(existing_album)
          Finder.stubs(:new).returns(finder)

          result = Importer.call(artist: @artist, title: "The Dark Side of the Moon")

          assert_equal existing_album, result
        end

        test "call handles MusicBrainz failures gracefully" do
          # Mock MusicBrainz search to fail (called twice - finder + provider)
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "Test Album")
            .twice
            .raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error").once

          result = Importer.call(artist: @artist, title: "Test Album")

          # Should fail because both finder and provider failed
          refute result.success?
        end

        test "call passes options to query" do
          search_service = mock
          search_service.expects(:search_primary_albums_only)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist, primary_albums_only: true)

          # Should fail because provider found no albums
          refute result.success?
        end

        test "call creates album when no MusicBrainz results found" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist)

          # Should fail because provider found no albums
          refute result.success?
        end

        test "call imports all albums when no title specified" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "first-album-mbid",
                    "title" => "First Album",
                    "first-release-date" => "1970"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist)

          assert result.success?
          assert_equal "First Album", result.item.title
          assert_equal 1970, result.item.release_year
        end

        test "call fails when artist has no MusicBrainz ID" do
          artist_without_mbid = music_artists(:roger_waters) # This artist has no MusicBrainz ID

          result = Importer.call(artist: artist_without_mbid, title: "Heroes")

          refute result.success?
          assert_includes result.all_errors.join(", "), "Artist has no MusicBrainz ID"
        end

        test "call handles primary albums only search" do
          search_service = mock
          search_service.expects(:search_primary_albums_only)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "studio-album-mbid",
                    "title" => "Studio Album",
                    "first-release-date" => "1975"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist, primary_albums_only: true)

          assert result.success?
          assert_equal "Studio Album", result.item.title
        end
      end
    end
  end
end
