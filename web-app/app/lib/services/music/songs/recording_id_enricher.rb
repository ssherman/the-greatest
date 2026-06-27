# frozen_string_literal: true

module Services
  module Music
    module Songs
      class RecordingIdEnricher
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        SEARCH_LIMIT = 50

        def self.call(song:, dry_run: false)
          new(song: song, dry_run: dry_run).call
        end

        def initialize(song:, dry_run: false)
          @song = song
          @dry_run = dry_run
          @recording_search = ::Music::Musicbrainz::Search::RecordingSearch.new
        end

        def call
          return skip_result("Song has no artists") if song.artists.empty?

          # Step 1: Search MusicBrainz for candidate recordings
          candidates = search_candidates
          return skip_result("No candidates found") if candidates.empty?

          # Step 2: Use AI to filter to exact matches
          ai_result = filter_with_ai(candidates)
          return error_result("AI task failed: #{ai_result.error}") unless ai_result.success?

          exact_matches = ai_result.data[:exact_matches] || []
          return skip_result("No exact matches found", candidates_found: candidates.count) if exact_matches.empty?

          # Validate AI matches against candidate MBIDs to prevent hallucinations
          candidate_mbids = candidates.map { |c| c["id"] }.to_set
          validated_matches = exact_matches.select { |mbid| candidate_mbids.include?(mbid) }
          hallucinated = exact_matches - validated_matches

          if hallucinated.any?
            Rails.logger.warn "RecordingIdEnricher: Song #{song.id} - AI returned #{hallucinated.count} MBID(s) not in candidate set: #{hallucinated.join(", ")}"
          end

          return skip_result("No valid matches after validation", candidates_found: candidates.count) if validated_matches.empty?

          # Step 3: Create identifiers for validated matches (unless dry run)
          new_count, existing_count = create_identifiers(validated_matches)

          Result.new(
            success?: true,
            data: {
              candidates_found: candidates.count,
              exact_matches: validated_matches.count,
              new_identifiers_created: new_count,
              existing_identifiers: existing_count,
              reasoning: ai_result.data[:reasoning]
            },
            errors: []
          )
        end

        private

        attr_reader :song, :dry_run, :recording_search

        def search_candidates
          primary_artist = song.artists.first
          return [] unless primary_artist

          # Prefer searching by artist MBID if available (more accurate)
          artist_mbids = primary_artist.identifiers
            .where(identifier_type: :music_musicbrainz_artist_id)
            .pluck(:value)

          if artist_mbids.any?
            search_by_artist_mbids(artist_mbids)
          else
            search_by_artist_name(primary_artist.name)
          end
        end

        def search_by_artist_mbids(artist_mbids)
          all_recordings = []
          seen_ids = Set.new

          artist_mbids.each do |mbid|
            result = recording_search.search_by_artist_mbid_and_title(
              mbid,
              song.title,
              limit: SEARCH_LIMIT
            )

            next unless result[:success]

            recordings = result[:data]["recordings"] || []
            recordings.each do |recording|
              # Deduplicate by recording ID across multiple artist MBID searches
              unless seen_ids.include?(recording["id"])
                seen_ids << recording["id"]
                all_recordings << recording
              end
            end
          end

          all_recordings
        end

        def search_by_artist_name(artist_name)
          result = recording_search.search_by_artist_and_title(
            artist_name,
            song.title,
            limit: SEARCH_LIMIT
          )

          return [] unless result[:success]

          result[:data]["recordings"] || []
        end

        def filter_with_ai(candidates)
          Services::Ai::Tasks::Music::Songs::RecordingMatcherTask.new(
            parent: song,
            candidates: candidates
          ).call
        end

        def create_identifiers(mbids)
          new_count = 0
          existing_count = 0

          mbids.each do |mbid|
            if dry_run
              # In dry run, check if it exists to report accurate counts
              if song.identifiers.exists?(identifier_type: :music_musicbrainz_recording_id, value: mbid)
                existing_count += 1
              else
                new_count += 1
              end
            else
              # Use find_or_create_by to handle race conditions
              identifier = song.identifiers.find_or_create_by!(
                identifier_type: :music_musicbrainz_recording_id,
                value: mbid
              )

              if identifier.previously_new_record?
                new_count += 1
              else
                existing_count += 1
              end
            end
          end

          [new_count, existing_count]
        end

        def skip_result(message, candidates_found: 0)
          Result.new(
            success?: true,
            data: {
              candidates_found: candidates_found,
              exact_matches: 0,
              new_identifiers_created: 0,
              existing_identifiers: 0,
              skip_reason: message
            },
            errors: []
          )
        end

        def error_result(message)
          Result.new(
            success?: false,
            data: {},
            errors: [message]
          )
        end
      end
    end
  end
end
