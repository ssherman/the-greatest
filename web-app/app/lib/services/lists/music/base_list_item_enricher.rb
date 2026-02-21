# frozen_string_literal: true

# Music base class for list item enrichment services.
# Inherits shared enrichment logic from Services::Lists::BaseListItemEnricher.
#
# Provides music-specific two-tier enrichment:
# 1. OpenSearch (local database search)
# 2. MusicBrainz (external API fallback)
#
# Subclasses must implement:
#   - opensearch_service_class: Service for OpenSearch lookups
#   - entity_class: Model class (e.g., Music::Song, Music::Album)
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - entity_name_key: Metadata key for entity name (e.g., "song_name")
#   - musicbrainz_search_service_class: Service for MusicBrainz lookups
#   - musicbrainz_response_key: Response key (e.g., "recordings", "release-groups")
#   - musicbrainz_id_key: Metadata key for MB ID (e.g., "mb_recording_id")
#   - musicbrainz_name_key: Metadata key for MB name (e.g., "mb_recording_name")
#   - lookup_existing_by_mb_id: Method to find existing entity by MB ID
#
module Services
  module Lists
    module Music
      class BaseListItemEnricher < ::Services::Lists::BaseListItemEnricher
        private

        # Music-specific abstract methods
        def musicbrainz_search_service_class
          raise NotImplementedError, "Subclass must implement #musicbrainz_search_service_class"
        end

        def musicbrainz_response_key
          raise NotImplementedError, "Subclass must implement #musicbrainz_response_key"
        end

        def musicbrainz_id_key
          raise NotImplementedError, "Subclass must implement #musicbrainz_id_key"
        end

        def musicbrainz_name_key
          raise NotImplementedError, "Subclass must implement #musicbrainz_name_key"
        end

        def lookup_existing_by_mb_id(mb_id)
          raise NotImplementedError, "Subclass must implement #lookup_existing_by_mb_id"
        end

        # Music-specific: include artist names in OpenSearch enrichment data
        def build_opensearch_enrichment_data(entity, score)
          super.merge("opensearch_artist_names" => entity.artists.pluck(:name))
        end

        # Implement external API search via MusicBrainz
        def find_via_external_api(title, artists)
          find_via_musicbrainz(title, artists)
        end

        def find_via_musicbrainz(title, artists)
          artist_name = artists.join(", ")
          search_result = search_service.search_by_artist_and_title(artist_name, title)

          Rails.logger.info "#{self.class.name}: MusicBrainz search for '#{title}' by '#{artist_name}' - success: #{search_result[:success]}, #{musicbrainz_response_key}: #{search_result[:data]&.dig(musicbrainz_response_key)&.length || 0}"

          unless search_result[:success] && search_result[:data][musicbrainz_response_key]&.any?
            if search_result[:errors]&.any?
              Rails.logger.warn "#{self.class.name}: MusicBrainz error for '#{title}': #{search_result[:errors].join(", ")}"
            end
            return {success: false, source: :musicbrainz, data: {}}
          end

          mb_entity = search_result[:data][musicbrainz_response_key].first
          mb_id = mb_entity["id"]
          mb_name = mb_entity["title"]

          artist_credits = mb_entity["artist-credit"] || []
          mb_artist_ids = artist_credits.map { |credit| credit.dig("artist", "id") }.compact
          mb_artist_names = artist_credits.map { |credit| credit.dig("artist", "name") }.compact

          existing_entity = lookup_existing_by_mb_id(mb_id)

          enrichment_data = {
            musicbrainz_id_key => mb_id,
            musicbrainz_name_key => mb_name,
            "mb_artist_ids" => mb_artist_ids,
            "mb_artist_names" => mb_artist_names,
            "musicbrainz_match" => true
          }

          if existing_entity
            enrichment_data[entity_id_key] = existing_entity.id
            enrichment_data[entity_name_key] = existing_entity.title
            @list_item.update!(
              listable_id: existing_entity.id,
              metadata: @list_item.metadata.merge(enrichment_data)
            )
            Rails.logger.debug "#{self.class.name}: MusicBrainz match (existing #{entity_type_name}) for '#{title}' -> #{existing_entity.title} (ID: #{existing_entity.id})"
          else
            @list_item.update!(metadata: @list_item.metadata.merge(enrichment_data))
            Rails.logger.debug "#{self.class.name}: MusicBrainz match (no local #{entity_type_name}) for '#{title}' -> MBID: #{mb_id}"
          end

          {:success => true, :source => :musicbrainz, entity_id_key.to_sym => existing_entity&.id, :data => enrichment_data}
        rescue => e
          Rails.logger.error "#{self.class.name}: MusicBrainz lookup failed: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          {success: false, source: :musicbrainz, data: {}}
        end

        def search_service
          @search_service ||= musicbrainz_search_service_class.new
        end
      end
    end
  end
end
