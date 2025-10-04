# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Song
      class FinderTest < ActiveSupport::TestCase
        def setup
          @finder = Finder.new
        end

        test "call returns existing song when found by MusicBrainz recording ID" do
          song = music_songs(:time)
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Create identifier for the song
          song.identifiers.create!(
            identifier_type: :music_musicbrainz_recording_id,
            value: mbid
          )

          query = ImportQuery.new(musicbrainz_recording_id: mbid)
          result = @finder.call(query: query)

          assert_equal song, result
        end

        test "call returns existing song when found by title" do
          song = music_songs(:time)
          query = ImportQuery.new(title: "Time")

          result = @finder.call(query: query)

          assert_equal song, result
        end

        test "call returns nil when no song found by MusicBrainz ID" do
          mbid = "00000000-1111-2222-3333-444444444444"
          query = ImportQuery.new(musicbrainz_recording_id: mbid)

          result = @finder.call(query: query)

          assert_nil result
        end

        test "call returns nil when no song found by title" do
          query = ImportQuery.new(title: "Nonexistent Song")
          result = @finder.call(query: query)

          assert_nil result
        end

        test "call prioritizes MusicBrainz ID over title when both present" do
          song1 = music_songs(:time)
          song2 = music_songs(:money)
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Give song1 a MusicBrainz ID
          song1.identifiers.create!(
            identifier_type: :music_musicbrainz_recording_id,
            value: mbid
          )

          # Query with MBID for song1 but title for song2
          query = ImportQuery.new(
            musicbrainz_recording_id: mbid,
            title: song2.title
          )

          result = @finder.call(query: query)

          # Should return song1 (found by MBID) not song2 (found by title)
          assert_equal song1, result
        end

        test "call handles query with only title" do
          song = music_songs(:money)
          query = ImportQuery.new(title: "Money")

          result = @finder.call(query: query)

          assert_equal song, result
        end

        test "call handles query with only musicbrainz_recording_id" do
          song = music_songs(:time)
          mbid = "test-recording-id-123"

          song.identifiers.create!(
            identifier_type: :music_musicbrainz_recording_id,
            value: mbid
          )

          query = ImportQuery.new(musicbrainz_recording_id: mbid)
          result = @finder.call(query: query)

          assert_equal song, result
        end

        test "call returns nil when title is blank" do
          query = ImportQuery.new(title: "")
          result = @finder.call(query: query)

          assert_nil result
        end
      end
    end
  end
end
