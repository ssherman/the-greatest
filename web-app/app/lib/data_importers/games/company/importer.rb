# frozen_string_literal: true

module DataImporters
  module Games
    module Company
      # Main importer for Games::Company records
      # Orchestrates finding existing companies and importing from IGDB
      class Importer < DataImporters::ImporterBase
        def self.call(igdb_id: nil, force_providers: false, **options)
          query = ImportQuery.new(igdb_id: igdb_id, **options)
          super(query: query, force_providers: force_providers)
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::Igdb.new
          ]
        end

        def initialize_item(query)
          ::Games::Company.new
        end
      end
    end
  end
end
