module Services
  module Lists
    module Music
      module Songs
        class ListItemEnricher
          def self.call(list_item:)
            new(list_item: list_item).call
          end

          def initialize(list_item:)
            @list_item = list_item
          end

          def call
            title = @list_item.metadata["title"]
            artists = @list_item.metadata["artists"]

            return not_found_result if title.blank? || artists.blank?

            opensearch_result = find_via_opensearch(title, artists)
            return opensearch_result if opensearch_result[:success]

            musicbrainz_result = find_via_musicbrainz(title, artists)
            return musicbrainz_result if musicbrainz_result[:success]

            not_found_result
          rescue => e
            Rails.logger.error "ListItemEnricher failed: #{e.message}"
            {success: false, source: :error, error: e.message, data: {}}
          end

          private

          attr_reader :list_item

          def find_via_opensearch(title, artists)
            search_results = ::Search::Music::Search::SongByTitleAndArtists.call(
              title: title,
              artists: artists,
              size: 1,
              min_score: 5.0
            )

            return {success: false, source: :opensearch, data: {}} if search_results.empty?

            result = search_results.first
            song_id = result[:id].to_i
            score = result[:score]

            song = ::Music::Song.find_by(id: song_id)
            return {success: false, source: :opensearch, data: {}} unless song

            enrichment_data = {
              "song_id" => song.id,
              "song_name" => song.title,
              "opensearch_match" => true,
              "opensearch_score" => score
            }

            @list_item.update!(
              listable_id: song.id,
              metadata: @list_item.metadata.merge(enrichment_data)
            )

            Rails.logger.debug "ListItemEnricher: OpenSearch match for '#{title}' -> #{song.title} (ID: #{song.id}, score: #{score})"

            {success: true, source: :opensearch, song_id: song.id, data: enrichment_data}
          rescue => e
            Rails.logger.error "ListItemEnricher: OpenSearch lookup failed: #{e.message}"
            {success: false, source: :opensearch, data: {}}
          end

          def find_via_musicbrainz(title, artists)
            artist_name = artists.join(", ")
            search_result = search_service.search_by_artist_and_title(artist_name, title)

            Rails.logger.info "ListItemEnricher: MusicBrainz search for '#{title}' by '#{artist_name}' - success: #{search_result[:success]}, recordings: #{search_result[:data]&.dig("recordings")&.length || 0}"

            unless search_result[:success] && search_result[:data]["recordings"]&.any?
              if search_result[:errors]&.any?
                Rails.logger.warn "ListItemEnricher: MusicBrainz error for '#{title}': #{search_result[:errors].join(", ")}"
              end
              return {success: false, source: :musicbrainz, data: {}}
            end

            recording = search_result[:data]["recordings"].first
            mb_recording_id = recording["id"]
            mb_recording_name = recording["title"]

            artist_credits = recording["artist-credit"] || []
            mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
            mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact

            existing_song = ::Music::Song.with_identifier(:music_musicbrainz_recording_id, mb_recording_id).first

            enrichment_data = {
              "mb_recording_id" => mb_recording_id,
              "mb_recording_name" => mb_recording_name,
              "mb_artist_ids" => mb_artist_ids,
              "mb_artist_names" => mb_artist_names,
              "musicbrainz_match" => true
            }

            if existing_song
              enrichment_data["song_id"] = existing_song.id
              enrichment_data["song_name"] = existing_song.title
              @list_item.update!(
                listable_id: existing_song.id,
                metadata: @list_item.metadata.merge(enrichment_data)
              )
              Rails.logger.debug "ListItemEnricher: MusicBrainz match (existing song) for '#{title}' -> #{existing_song.title} (ID: #{existing_song.id})"
            else
              @list_item.update!(metadata: @list_item.metadata.merge(enrichment_data))
              Rails.logger.debug "ListItemEnricher: MusicBrainz match (no local song) for '#{title}' -> MBID: #{mb_recording_id}"
            end

            {success: true, source: :musicbrainz, song_id: existing_song&.id, data: enrichment_data}
          rescue => e
            Rails.logger.error "ListItemEnricher: MusicBrainz lookup failed: #{e.class} - #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            {success: false, source: :musicbrainz, data: {}}
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::RecordingSearch.new
          end

          def not_found_result
            {success: false, source: :not_found, data: {}}
          end
        end
      end
    end
  end
end
