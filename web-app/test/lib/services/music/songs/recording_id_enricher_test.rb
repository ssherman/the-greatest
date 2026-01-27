require "test_helper"

module Services
  module Music
    module Songs
      class RecordingIdEnricherTest < ActiveSupport::TestCase
        def setup
          @song = music_songs(:wish_you_were_here)
          @artist = music_artists(:pink_floyd)
          @recording_search = mock
          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(@recording_search)
        end

        test "returns skip result when song has no artists" do
          @song.song_artists.destroy_all

          result = RecordingIdEnricher.call(song: @song)

          assert result.success?
          assert_equal "Song has no artists", result.data[:skip_reason]
          assert_equal 0, result.data[:candidates_found]
        end

        test "returns skip result when no candidates found" do
          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: true,
            data: {"recordings" => []}
          })

          result = RecordingIdEnricher.call(song: @song)

          assert result.success?
          assert_equal "No candidates found", result.data[:skip_reason]
        end

        test "returns skip result when search fails" do
          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: false,
            errors: ["API error"]
          })

          result = RecordingIdEnricher.call(song: @song)

          assert result.success?
          assert_equal "No candidates found", result.data[:skip_reason]
        end

        test "calls AI task with candidates and creates identifiers" do
          candidates = [
            {"id" => "mbid-1", "title" => "Wish You Were Here", "artist-credit" => [{"name" => "Pink Floyd"}]},
            {"id" => "mbid-2", "title" => "Wish You Were Here (live)", "artist-credit" => [{"name" => "Pink Floyd"}]}
          ]

          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: true,
            data: {"recordings" => candidates}
          })

          ai_result = Services::Ai::Result.new(
            success: true,
            data: {
              exact_matches: ["mbid-1"],
              reasoning: "Selected studio version"
            }
          )

          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.any_instance.stubs(:call).returns(ai_result)

          result = RecordingIdEnricher.call(song: @song)

          assert result.success?
          assert_equal 2, result.data[:candidates_found]
          assert_equal 1, result.data[:exact_matches]
          assert_equal 1, result.data[:new_identifiers_created]
          assert_equal 0, result.data[:existing_identifiers]

          # Verify identifier was created
          assert @song.identifiers.exists?(
            identifier_type: :music_musicbrainz_recording_id,
            value: "mbid-1"
          )
        end

        test "does not create duplicate identifiers" do
          # Create existing identifier
          @song.identifiers.create!(
            identifier_type: :music_musicbrainz_recording_id,
            value: "mbid-existing"
          )

          candidates = [
            {"id" => "mbid-existing", "title" => "Wish You Were Here", "artist-credit" => [{"name" => "Pink Floyd"}]},
            {"id" => "mbid-new", "title" => "Wish You Were Here", "artist-credit" => [{"name" => "Pink Floyd"}]}
          ]

          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: true,
            data: {"recordings" => candidates}
          })

          ai_result = Services::Ai::Result.new(
            success: true,
            data: {
              exact_matches: ["mbid-existing", "mbid-new"],
              reasoning: "Both are studio versions"
            }
          )

          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.any_instance.stubs(:call).returns(ai_result)

          result = RecordingIdEnricher.call(song: @song)

          assert result.success?
          assert_equal 1, result.data[:new_identifiers_created]
          assert_equal 1, result.data[:existing_identifiers]

          # Verify only 2 identifiers total (existing + new)
          assert_equal 2, @song.identifiers.where(identifier_type: :music_musicbrainz_recording_id).count
        end

        test "dry run does not create identifiers" do
          candidates = [
            {"id" => "mbid-dry-run", "title" => "Wish You Were Here", "artist-credit" => [{"name" => "Pink Floyd"}]}
          ]

          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: true,
            data: {"recordings" => candidates}
          })

          ai_result = Services::Ai::Result.new(
            success: true,
            data: {
              exact_matches: ["mbid-dry-run"],
              reasoning: "Match found"
            }
          )

          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.any_instance.stubs(:call).returns(ai_result)

          result = RecordingIdEnricher.call(song: @song, dry_run: true)

          assert result.success?
          assert_equal 1, result.data[:new_identifiers_created]

          # Verify identifier was NOT created
          refute @song.identifiers.exists?(
            identifier_type: :music_musicbrainz_recording_id,
            value: "mbid-dry-run"
          )
        end

        test "returns error when AI task fails" do
          candidates = [
            {"id" => "mbid-1", "title" => "Wish You Were Here", "artist-credit" => [{"name" => "Pink Floyd"}]}
          ]

          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: true,
            data: {"recordings" => candidates}
          })

          ai_result = Services::Ai::Result.new(
            success: false,
            error: "AI service unavailable"
          )

          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.any_instance.stubs(:call).returns(ai_result)

          result = RecordingIdEnricher.call(song: @song)

          refute result.success?
          assert_includes result.errors.first, "AI task failed"
        end

        test "returns skip result when AI returns no exact matches" do
          candidates = [
            {"id" => "mbid-1", "title" => "Wish You Were Here (live)", "artist-credit" => [{"name" => "Pink Floyd"}]}
          ]

          @recording_search.stubs(:search_by_artist_mbid_and_title).returns({
            success: true,
            data: {"recordings" => candidates}
          })

          ai_result = Services::Ai::Result.new(
            success: true,
            data: {
              exact_matches: [],
              reasoning: "No exact matches"
            }
          )

          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.any_instance.stubs(:call).returns(ai_result)

          result = RecordingIdEnricher.call(song: @song)

          assert result.success?
          assert_equal "No exact matches found", result.data[:skip_reason]
          assert_equal 1, result.data[:candidates_found]
        end

        test "uses artist MBID for search when available" do
          # Pink Floyd has MBID in fixtures
          @recording_search.expects(:search_by_artist_mbid_and_title).with(
            "83d91898-7763-47d7-b03b-b92132375c47",
            "Wish You Were Here",
            limit: 50
          ).returns({success: true, data: {"recordings" => []}})

          RecordingIdEnricher.call(song: @song)
        end

        test "falls back to artist name search when no MBID" do
          # Remove the artist's MBID
          @artist.identifiers.where(identifier_type: :music_musicbrainz_artist_id).destroy_all

          @recording_search.expects(:search_by_artist_and_title).with(
            "Pink Floyd",
            "Wish You Were Here",
            limit: 50
          ).returns({success: true, data: {"recordings" => []}})

          RecordingIdEnricher.call(song: @song)
        end

        test "searches all artist MBIDs and deduplicates results" do
          # Add a second MBID for Pink Floyd
          @artist.identifiers.create!(
            identifier_type: :music_musicbrainz_artist_id,
            value: "second-mbid-for-pink-floyd"
          )

          # Same recording returned by both searches
          recording1 = {"id" => "recording-1", "title" => "Wish You Were Here", "artist-credit" => [{"name" => "Pink Floyd"}]}
          recording2 = {"id" => "recording-2", "title" => "Wish You Were Here (live)", "artist-credit" => [{"name" => "Pink Floyd"}]}

          @recording_search.stubs(:search_by_artist_mbid_and_title).with(
            "83d91898-7763-47d7-b03b-b92132375c47",
            "Wish You Were Here",
            limit: 50
          ).returns({success: true, data: {"recordings" => [recording1, recording2]}})

          @recording_search.stubs(:search_by_artist_mbid_and_title).with(
            "second-mbid-for-pink-floyd",
            "Wish You Were Here",
            limit: 50
          ).returns({success: true, data: {"recordings" => [recording1]}})  # Duplicate recording1

          ai_result = Services::Ai::Result.new(
            success: true,
            data: {exact_matches: [], reasoning: "No matches"}
          )

          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.any_instance.stubs(:call).returns(ai_result)

          result = RecordingIdEnricher.call(song: @song)

          # Should have 2 unique candidates, not 3
          assert_equal 2, result.data[:candidates_found]
        end

        test "uses correct search limit" do
          assert_equal 50, RecordingIdEnricher::SEARCH_LIMIT
        end
      end
    end
  end
end
