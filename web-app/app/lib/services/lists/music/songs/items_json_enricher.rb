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

            songs_data = @list.items_json["songs"]

            enriched_songs = songs_data.map do |song_entry|
              enrichment = enrich_song_entry(song_entry)

              if enrichment[:success]
                enriched_count += 1
                song_entry.merge(enrichment[:data])
              else
                skipped_count += 1
                Rails.logger.warn "Skipped enrichment for #{song_entry["title"]} by #{song_entry["artists"].join(", ")}: #{enrichment[:error]}"
                song_entry
              end
            end

            @list.update!(items_json: {"songs" => enriched_songs})

            success_result(enriched_count, skipped_count, songs_data.length)
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
            artist_name = song_entry["artists"].join(", ")
            title = song_entry["title"]

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
              "mb_artist_names" => mb_artist_names
            }

            if song_id
              enrichment_data["song_id"] = song_id
              enrichment_data["song_name"] = song_name
            end

            {success: true, data: enrichment_data}
          rescue => e
            {success: false, error: e.message}
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::RecordingSearch.new
          end

          def success_result(enriched_count, skipped_count, total_count)
            {
              success: true,
              message: "Enriched #{enriched_count} of #{total_count} songs (#{skipped_count} skipped)",
              enriched_count: enriched_count,
              skipped_count: skipped_count,
              total_count: total_count
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
