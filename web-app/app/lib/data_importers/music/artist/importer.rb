# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      # Main importer for Music::Artist records
      # Orchestrates finding existing artists and importing from providers
      class Importer < DataImporters::ImporterBase
        def self.call(name: nil, musicbrainz_id: nil, **options)
          query = ImportQuery.new(name: name, musicbrainz_id: musicbrainz_id, **options)
          super(query: query)
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::MusicBrainz.new
            # Future: Add more providers here
            # Providers::Discogs.new,
            # Providers::AllMusic.new,
            # Providers::Wikipedia.new
          ]
        end

        def initialize_item(query)
          # Initialize with name if available, otherwise will be populated by provider
          ::Music::Artist.new(name: query.name)
        end
      end
    end
  end
end
