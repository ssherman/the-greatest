# frozen_string_literal: true

module DataImporters
  module Games
    module Company
      # Finds an existing Games::Company before import and answers with a
      # Match. Companies have no ranking, no search index and no external
      # search; the IGDB company id is the lookup, now and after increment 5.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Games::Company

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return nil if query.igdb_id.blank?

          find_by_identifier(
            identifier_type: :games_igdb_company_id,
            identifier_value: query.igdb_id.to_s,
            model_class: ::Games::Company
          )
        end
      end
    end
  end
end
