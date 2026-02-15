# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      # Main importer for Games::Game records
      # Orchestrates finding existing games and importing from providers
      class Importer < DataImporters::ImporterBase
        def self.call(igdb_id: nil, item: nil, force_providers: false, providers: nil, **options)
          if item.present?
            # Item-based import: use provided game
            super(item: item, force_providers: force_providers, providers: providers)
          else
            # Query-based import: create query object
            query = ImportQuery.new(igdb_id: igdb_id, **options)
            super(query: query, force_providers: force_providers, providers: providers)
          end
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::Igdb.new,
            Providers::CoverArt.new,
            Providers::Amazon.new
          ]
        end

        def initialize_item(query)
          ::Games::Game.new
        end
      end
    end
  end
end
