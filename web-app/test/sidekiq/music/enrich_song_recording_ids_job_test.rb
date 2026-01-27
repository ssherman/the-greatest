# frozen_string_literal: true

require "test_helper"

module Music
  class EnrichSongRecordingIdsJobTest < ActiveSupport::TestCase
    def setup
      @song = music_songs(:wish_you_were_here)
      @artist = music_artists(:pink_floyd)
      @job = EnrichSongRecordingIdsJob.new
    end

    test "job is configured for serial queue" do
      assert_equal :serial, EnrichSongRecordingIdsJob.get_sidekiq_options["queue"]
    end

    test "job includes Sidekiq::Job" do
      assert EnrichSongRecordingIdsJob.included_modules.include?(Sidekiq::Job)
    end

    test "perform delegates to enrichment service which handles no artists" do
      @song.song_artists.destroy_all

      # Service returns skip result for songs with no artists
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 0,
          exact_matches: 0,
          new_identifiers_created: 0,
          existing_identifiers: 0,
          skip_reason: "Song has no artists"
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)

      assert_nothing_raised do
        @job.perform(@song.id)
      end
    end

    test "perform calls enrichment service even without artist MBID (uses name fallback)" do
      @artist.identifiers.where(identifier_type: :music_musicbrainz_artist_id).destroy_all

      # Service uses name-based search as fallback
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 3,
          exact_matches: 1,
          new_identifiers_created: 1,
          existing_identifiers: 0
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)
      Music::Song.any_instance.stubs(:update_release_year_from_identifiers!).returns(true)

      assert_nothing_raised do
        @job.perform(@song.id)
      end
    end

    test "perform calls enrichment service" do
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 5,
          exact_matches: 2,
          new_identifiers_created: 2,
          existing_identifiers: 0,
          reasoning: "Test reasoning"
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)
      Music::Song.any_instance.stubs(:update_release_year_from_identifiers!).returns(true)

      assert_nothing_raised do
        @job.perform(@song.id)
      end
    end

    test "perform updates release year when new identifiers created" do
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 5,
          exact_matches: 2,
          new_identifiers_created: 2,
          existing_identifiers: 0
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)
      Music::Song.any_instance.expects(:update_release_year_from_identifiers!).once

      @job.perform(@song.id)
    end

    test "perform updates release year even when only existing identifiers" do
      # This handles retry scenarios where identifiers were created but release year update failed
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 5,
          exact_matches: 1,
          new_identifiers_created: 0,
          existing_identifiers: 1
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)
      Music::Song.any_instance.expects(:update_release_year_from_identifiers!).once

      @job.perform(@song.id)
    end

    test "perform does not update release year when no recording IDs found" do
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 5,
          exact_matches: 0,
          new_identifiers_created: 0,
          existing_identifiers: 0
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)
      Music::Song.any_instance.expects(:update_release_year_from_identifiers!).never

      @job.perform(@song.id)
    end

    test "perform does not update release year when skipped" do
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: true,
        data: {
          candidates_found: 0,
          exact_matches: 0,
          new_identifiers_created: 0,
          existing_identifiers: 0,
          skip_reason: "No candidates found"
        },
        errors: []
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)
      Music::Song.any_instance.expects(:update_release_year_from_identifiers!).never

      @job.perform(@song.id)
    end

    test "perform raises error on enrichment failure to trigger retry" do
      result = Services::Music::Songs::RecordingIdEnricher::Result.new(
        success?: false,
        data: {},
        errors: ["AI service unavailable"]
      )

      Services::Music::Songs::RecordingIdEnricher.stubs(:call).returns(result)

      error = assert_raises(StandardError) do
        @job.perform(@song.id)
      end

      assert_includes error.message, "AI service unavailable"
    end

    test "perform handles missing song gracefully" do
      assert_raises(ActiveRecord::RecordNotFound) do
        @job.perform(999_999_999)
      end
    end
  end
end
