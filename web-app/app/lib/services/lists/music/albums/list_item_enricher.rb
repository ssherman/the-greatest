# frozen_string_literal: true

module Services
  module Lists
    module Music
      module Albums
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
            search_results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
              title: title,
              artists: artists,
              size: 1,
              min_score: 5.0
            )

            return {success: false, source: :opensearch, data: {}} if search_results.empty?

            result = search_results.first
            album_id = result[:id].to_i
            score = result[:score]

            album = ::Music::Album.find_by(id: album_id)
            return {success: false, source: :opensearch, data: {}} unless album

            enrichment_data = {
              "album_id" => album.id,
              "album_name" => album.title,
              "opensearch_artist_names" => album.artists.pluck(:name),
              "opensearch_match" => true,
              "opensearch_score" => score
            }

            @list_item.update!(
              listable_id: album.id,
              metadata: @list_item.metadata.merge(enrichment_data)
            )

            Rails.logger.debug "ListItemEnricher: OpenSearch match for '#{title}' -> #{album.title} (ID: #{album.id}, score: #{score})"

            {success: true, source: :opensearch, album_id: album.id, data: enrichment_data}
          rescue => e
            Rails.logger.error "ListItemEnricher: OpenSearch lookup failed: #{e.message}"
            {success: false, source: :opensearch, data: {}}
          end

          def find_via_musicbrainz(title, artists)
            artist_name = artists.join(", ")
            search_result = search_service.search_by_artist_and_title(artist_name, title)

            Rails.logger.info "ListItemEnricher: MusicBrainz search for '#{title}' by '#{artist_name}' - success: #{search_result[:success]}, release_groups: #{search_result[:data]&.dig("release-groups")&.length || 0}"

            unless search_result[:success] && search_result[:data]["release-groups"]&.any?
              if search_result[:errors]&.any?
                Rails.logger.warn "ListItemEnricher: MusicBrainz error for '#{title}': #{search_result[:errors].join(", ")}"
              end
              return {success: false, source: :musicbrainz, data: {}}
            end

            release_group = search_result[:data]["release-groups"].first
            mb_release_group_id = release_group["id"]
            mb_release_group_name = release_group["title"]

            artist_credits = release_group["artist-credit"] || []
            mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
            mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact

            existing_album = ::Music::Album.with_musicbrainz_release_group_id(mb_release_group_id).first

            enrichment_data = {
              "mb_release_group_id" => mb_release_group_id,
              "mb_release_group_name" => mb_release_group_name,
              "mb_artist_ids" => mb_artist_ids,
              "mb_artist_names" => mb_artist_names,
              "musicbrainz_match" => true
            }

            if existing_album
              enrichment_data["album_id"] = existing_album.id
              enrichment_data["album_name"] = existing_album.title
              @list_item.update!(
                listable_id: existing_album.id,
                metadata: @list_item.metadata.merge(enrichment_data)
              )
              Rails.logger.debug "ListItemEnricher: MusicBrainz match (existing album) for '#{title}' -> #{existing_album.title} (ID: #{existing_album.id})"
            else
              @list_item.update!(metadata: @list_item.metadata.merge(enrichment_data))
              Rails.logger.debug "ListItemEnricher: MusicBrainz match (no local album) for '#{title}' -> MBID: #{mb_release_group_id}"
            end

            {success: true, source: :musicbrainz, album_id: existing_album&.id, data: enrichment_data}
          rescue => e
            Rails.logger.error "ListItemEnricher: MusicBrainz lookup failed: #{e.class} - #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            {success: false, source: :musicbrainz, data: {}}
          end

          def search_service
            @search_service ||= ::Music::Musicbrainz::Search::ReleaseGroupSearch.new
          end

          def not_found_result
            {success: false, source: :not_found, data: {}}
          end
        end
      end
    end
  end
end
