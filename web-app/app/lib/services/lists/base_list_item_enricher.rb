# frozen_string_literal: true

# Base class for list item enrichment services.
# Provides shared enrichment logic for list items across domains.
#
# Implements a two-tier enrichment strategy:
# 1. OpenSearch (local database search) - fast, no external API calls
# 2. External API fallback - domain-specific external service
#
# Subclasses must implement:
#   - opensearch_service_class: Service for OpenSearch lookups
#   - entity_class: Model class (e.g., Music::Song, Games::Game)
#   - entity_id_key: Metadata key for entity ID (e.g., "song_id")
#   - entity_name_key: Metadata key for entity name (e.g., "song_name")
#   - find_via_external_api(title, artists): External API search method
#
module Services
  module Lists
    class BaseListItemEnricher
      def self.call(list_item:)
        new(list_item: list_item).call
      end

      def initialize(list_item:)
        @list_item = list_item
      end

      def call
        title = @list_item.metadata["title"]
        artists = @list_item.metadata[metadata_artists_key]

        return not_found_result if title.blank?
        return not_found_result if require_artists? && artists.blank?

        opensearch_result = find_via_opensearch(title, artists)
        return opensearch_result if opensearch_result[:success]

        external_result = find_via_external_api(title, artists)
        return external_result if external_result[:success]

        not_found_result
      rescue => e
        Rails.logger.error "#{self.class.name} failed: #{e.message}"
        {success: false, source: :error, error: e.message, data: {}}
      end

      private

      attr_reader :list_item

      # Abstract methods - subclasses must implement
      def opensearch_service_class
        raise NotImplementedError, "Subclass must implement #opensearch_service_class"
      end

      def entity_class
        raise NotImplementedError, "Subclass must implement #entity_class"
      end

      def entity_id_key
        raise NotImplementedError, "Subclass must implement #entity_id_key"
      end

      def entity_name_key
        raise NotImplementedError, "Subclass must implement #entity_name_key"
      end

      # Returns the metadata key for the "artists" field.
      # Override in subclasses where the key name differs (e.g., "developers" for games).
      def metadata_artists_key
        "artists"
      end

      # Whether artists/developers are required for enrichment.
      # Music requires artists (title alone is too ambiguous for songs/albums).
      # Games can enrich by title alone via IGDB.
      def require_artists?
        true
      end

      # Subclasses must implement: search external API and return result hash
      # Should return {success: true/false, source: :symbol, data: {}}
      # and update @list_item metadata/listable_id if match found
      def find_via_external_api(title, artists)
        raise NotImplementedError, "Subclass must implement #find_via_external_api"
      end

      # Shared implementation methods

      def find_via_opensearch(title, artists)
        search_results = opensearch_service_class.call(
          title: title,
          artists: artists,
          size: 1,
          min_score: 5.0
        )

        return {success: false, source: :opensearch, data: {}} if search_results.empty?

        result = search_results.first
        entity_id = result[:id].to_i
        score = result[:score]

        entity = entity_class.find_by(id: entity_id)
        return {success: false, source: :opensearch, data: {}} unless entity

        enrichment_data = build_opensearch_enrichment_data(entity, score)

        @list_item.update!(
          listable_id: entity.id,
          metadata: @list_item.metadata.merge(enrichment_data)
        )

        Rails.logger.debug "#{self.class.name}: OpenSearch match for '#{title}' -> #{entity.title} (ID: #{entity.id}, score: #{score})"

        {:success => true, :source => :opensearch, entity_id_key.to_sym => entity.id, :data => enrichment_data}
      rescue => e
        Rails.logger.error "#{self.class.name}: OpenSearch lookup failed: #{e.message}"
        {success: false, source: :opensearch, data: {}}
      end

      # Override in subclasses to customize OpenSearch enrichment data
      def build_opensearch_enrichment_data(entity, score)
        {
          entity_id_key => entity.id,
          entity_name_key => entity.title,
          "opensearch_match" => true,
          "opensearch_score" => score
        }
      end

      def not_found_result
        {success: false, source: :not_found, data: {}}
      end

      def entity_type_name
        entity_class.name.demodulize.downcase
      end
    end
  end
end
