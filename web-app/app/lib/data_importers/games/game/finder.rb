# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      # Finds an existing Games::Game before import and answers with a Match.
      # Increment 1: the IGDB id lookup runs as the single decisive source;
      # increment 5 adds the exact, OpenSearch and IGDB search sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Games::Game

        def ranking_configuration_class = ::Games::RankingConfiguration

        # Evidence for the audit pages and the AI prompt. The legacy source
        # decides on its own, so these do not change any decision yet.
        def record_creators(record) = record.companies.map(&:name)

        def record_year(record) = record.release_year

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return nil if query.igdb_id.blank?

          find_by_identifier(
            identifier_type: :games_igdb_id,
            identifier_value: query.igdb_id.to_s,
            model_class: ::Games::Game
          )
        end
      end
    end
  end
end
