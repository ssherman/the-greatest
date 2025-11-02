module Services
  module Lists
    module Music
      module Songs
        class ItemsJsonEnricher
          def self.call(list:)
            new(list: list).call
          end

          def initialize(list:)
            @list = list
          end

          def call
            validate_list!

            enriched_count = 0
            skipped_count = 0
            opensearch_matches = 0
            musicbrainz_matches = 0

            songs_data = @list.items_json["songs"]

            enriched_songs = songs_data.map do |song_entry|
              enrichment = enrich_song_entry(song_entry)

              if enrichment[:success]
                enriched_count += 1

                if enrichment[:source] == :opensearch
                  opensearch_matches += 1
                elsif enrichment[:source] == :musicbrainz
                  musicbrainz_matches += 1
                end

                song_entry.merge(enrichment[:data])
              else
                skipped_count += 1
                Rails.logger.warn "Skipped enrichment for #{song_entry["title"]} by #{song_entry["artists"].join(", ")}: #{enrichment[:error]}"
                song_entry
              end
            end

            @list.update!(items_json: {"songs" => enriched_songs})

            success_result(enriched_count, skipped_count, songs_data.length, opensearch_matches, musicbrainz_matches)
          rescue ArgumentError
            raise
          rescue => e
            Rails.logger.error "ItemsJsonEnricher failed: #{e.message}"
            failure_result(e.message)
          end

          private

          attr_reader :list

          def validate_list!
            raise ArgumentError, "List must be a Music::Songs::List" unless @list.is_a?(::Music::Songs::List)
            raise ArgumentError, "List must have items_json populated" unless @list.items_json.present?
            raise ArgumentError, "List items_json must contain songs array" unless @list.items_json["songs"].is_a?(Array)
          end

          def enrich_song_entry(song_entry)
            title = song_entry["title"]
            artists = song_entry["artists"]

            opensearch_match = find_local_song(title, artists)

            if opensearch_match
              Rails.logger.info "Found local song via OpenSearch: #{opensearch_match[:song].title} (ID: #{opensearch_match[:song].id}, score: #{opensearch_match[:score]})"

              enrichment_data = {
                "song_id" => opensearch_match[:song].id,
                "song_name" => opensearch_match[:song].title,
                "opensearch_match" => true,
                "opensearch_score" => opensearch_match[:score]
              }

              return {success: true, data: enrichment_data, source: :opensearch}
            end

            Rails.logger.info "No local song found via OpenSearch, trying MusicBrainz for: #{title} by #{artists.join(", ")}"

            artist_name = artists.join(", ")
            search_result = search_service.search_by_artist_and_title(artist_name, title)

            unless search_result[:success] && search_result[:data]["recordings"]&.any?
              return {success: false, error: "No MusicBrainz match found"}
            end

            recording = search_result[:data]["recordings"].first
            mb_recording_id = recording["id"]
            mb_recording_name = recording["title"]

            artist_credits = recording["artist-credit"] || []
            mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
            mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact

            existing_song = ::Music::Song.with_identifier(:music_musicbrainz_recording_id, mb_recording_id).first
            song_id = existing_song&.id
            song_name = existing_song&.title

            enrichment_data = {
              "mb_recording_id" => mb_recording_id,
              "mb_recording_name" => mb_recording_name,
              "mb_artist_ids" => mb_artist_ids,
              "mb_artist_names" => mb_artist_names,
              "musicbrainz_match" => true
            }

            if song_id
              enrichment_data["song_id"] = song_id
              enrichment_data["song_name"] = song_name
            end

            {success: true, data: enrichment_data, source: :musicbrainz}
          rescue => e
            {success: false, error: e.message}
          end

          def find_local_song(title, artists)
            return nil if title.blank? || artists.blank?

            search_results = ::Search::Music::Search::SongByTitleAndArtists.call(
              title: title,
              artists: artists,
              size: 1,
              min_score: 5.0
            )

            return nil if search_results.empty?

            result = search_results.first
            song_id = result[:id].to_i
            score = result[:score]

            song = ::Music::Song.find_by(id: song_id)

            return nil unless song

            {song: song, score: score}
          rescue => e
            Rails.logger.error "Error searching OpenSearch for local song: #{e.message}"
            nil
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::RecordingSearch.new
          end

          def success_result(enriched_count, skipped_count, total_count, opensearch_matches, musicbrainz_matches)
            {
              success: true,
              message: "Enriched #{enriched_count} of #{total_count} songs (#{opensearch_matches} from OpenSearch, #{musicbrainz_matches} from MusicBrainz, #{skipped_count} skipped)",
              enriched_count: enriched_count,
              skipped_count: skipped_count,
              total_count: total_count,
              opensearch_matches: opensearch_matches,
              musicbrainz_matches: musicbrainz_matches
            }
          end

          def failure_result(error_message)
            {
              success: false,
              message: error_message,
              enriched_count: 0,
              skipped_count: 0,
              total_count: 0
            }
          end
        end
      end
    end
  end
end
