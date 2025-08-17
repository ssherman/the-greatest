# frozen_string_literal: true

module DataImporters
  module Music
    module Release
      class Importer < ImporterBase
        def self.call(album:)
          query = ImportQuery.new(album: album)
          new.call(query: query)
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::MusicBrainz.new
          ]
        end

        # Release import creates multiple items, not a single item
        def multi_item_import?
          true
        end
      end
    end
  end
end
