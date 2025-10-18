module Services
  module Lists
    module Music
      module Albums
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

            albums_data = @list.items_json["albums"]

            enriched_albums = albums_data.map do |album_entry|
              enrichment = enrich_album_entry(album_entry)

              if enrichment[:success]
                enriched_count += 1
                album_entry.merge(enrichment[:data])
              else
                skipped_count += 1
                Rails.logger.warn "Skipped enrichment for #{album_entry["title"]} by #{album_entry["artists"].join(", ")}: #{enrichment[:error]}"
                album_entry
              end
            end

            # Update list with enriched data
            @list.update!(items_json: {"albums" => enriched_albums})

            success_result(enriched_count, skipped_count, albums_data.length)
          rescue ArgumentError
            # Re-raise validation errors
            raise
          rescue => e
            Rails.logger.error "ItemsJsonEnricher failed: #{e.message}"
            failure_result(e.message)
          end

          private

          attr_reader :list

          def validate_list!
            raise ArgumentError, "List must be a Music::Albums::List" unless @list.is_a?(::Music::Albums::List)
            raise ArgumentError, "List must have items_json populated" unless @list.items_json.present?
            raise ArgumentError, "List items_json must contain albums array" unless @list.items_json["albums"].is_a?(Array)
          end

          def enrich_album_entry(album_entry)
            artist_name = album_entry["artists"].join(", ")
            title = album_entry["title"]

            # Search MusicBrainz for release group
            search_result = search_service.search_by_artist_and_title(artist_name, title)

            unless search_result[:success] && search_result[:data]["release-groups"]&.any?
              return {success: false, error: "No MusicBrainz match found"}
            end

            # Take first result
            release_group = search_result[:data]["release-groups"].first
            mb_release_group_id = release_group["id"]
            mb_release_group_name = release_group["title"]

            # Extract artist credits from release group
            artist_credits = release_group["artist-credit"] || []
            mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
            mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact

            # Check if album exists in database
            existing_album = ::Music::Album.with_musicbrainz_release_group_id(mb_release_group_id).first
            album_id = existing_album&.id
            album_name = existing_album&.title

            enrichment_data = {
              "mb_release_group_id" => mb_release_group_id,
              "mb_release_group_name" => mb_release_group_name,
              "mb_artist_ids" => mb_artist_ids,
              "mb_artist_names" => mb_artist_names
            }

            # Only add album_id and album_name if album exists
            if album_id
              enrichment_data["album_id"] = album_id
              enrichment_data["album_name"] = album_name
            end

            {success: true, data: enrichment_data}
          rescue => e
            {success: false, error: e.message}
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::ReleaseGroupSearch.new
          end

          def success_result(enriched_count, skipped_count, total_count)
            {
              success: true,
              message: "Enriched #{enriched_count} of #{total_count} albums (#{skipped_count} skipped)",
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
