# frozen_string_literal: true

# Games list item enricher.
# Inherits shared enrichment logic from Services::Lists::BaseListItemEnricher.
#
# Searches OpenSearch and IGDB to match list items to games.
#
# Two-tier strategy:
# 1. OpenSearch (local database) - search by title + developer names
# 2. IGDB fallback - search by game name, store igdb_id for import
#
module Services
  module Lists
    module Games
      class ListItemEnricher < ::Services::Lists::BaseListItemEnricher
        private

        def opensearch_service_class
          ::Search::Games::Search::GameByTitleAndDevelopers
        end

        def entity_class
          ::Games::Game
        end

        def entity_id_key
          "game_id"
        end

        def entity_name_key
          "game_name"
        end

        def metadata_artists_key
          "developers"
        end

        def require_artists?
          false
        end

        def find_via_external_api(title, developers)
          find_via_igdb(title, developers)
        end

        IGDB_SEARCH_FIELDS = %w[
          name slug first_release_date
          cover.image_id
          involved_companies.company.name involved_companies.developer
        ].freeze

        def find_via_igdb(title, developers)
          search_result = igdb_game_search.search_by_name(title, limit: 5, fields: IGDB_SEARCH_FIELDS)

          unless search_result[:success] && search_result[:data]&.any?
            return {success: false, source: :igdb, data: {}}
          end

          igdb_game = search_result[:data].first
          igdb_id = igdb_game["id"]
          igdb_name = igdb_game["name"]

          # Extract developer names from involved_companies
          involved_companies = igdb_game["involved_companies"] || []
          igdb_developer_names = involved_companies
            .select { |ic| ic["developer"] }
            .map { |ic| ic.dig("company", "name") }
            .compact

          # Check if we have an existing game with this IGDB ID
          existing_game = ::Games::Game.with_igdb_id(igdb_id).first

          enrichment_data = {
            "igdb_id" => igdb_id,
            "igdb_name" => igdb_name,
            "igdb_developer_names" => igdb_developer_names,
            "igdb_match" => true
          }

          if existing_game
            enrichment_data["game_id"] = existing_game.id
            enrichment_data["game_name"] = existing_game.title
            @list_item.update!(
              listable_id: existing_game.id,
              metadata: @list_item.metadata.merge(enrichment_data)
            )
            Rails.logger.debug "#{self.class.name}: IGDB match (existing game) for '#{title}' -> #{existing_game.title} (ID: #{existing_game.id})"
          else
            @list_item.update!(metadata: @list_item.metadata.merge(enrichment_data))
            Rails.logger.debug "#{self.class.name}: IGDB match (no local game) for '#{title}' -> IGDB ID: #{igdb_id}"
          end

          {success: true, source: :igdb, game_id: existing_game&.id, data: enrichment_data}
        rescue => e
          Rails.logger.error "#{self.class.name}: IGDB lookup failed: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          {success: false, source: :igdb, data: {}}
        end

        def igdb_game_search
          @igdb_game_search ||= ::Games::Igdb::Search::GameSearch.new
        end
      end
    end
  end
end
