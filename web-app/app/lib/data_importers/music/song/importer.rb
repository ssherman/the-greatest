# frozen_string_literal: true

module DataImporters
  module Music
    module Song
      class Importer < DataImporters::ImporterBase
        def self.call(title: nil, musicbrainz_recording_id: nil, force_providers: false, **options)
          query = ImportQuery.new(title: title, musicbrainz_recording_id: musicbrainz_recording_id, **options)
          super(query: query, force_providers: force_providers)
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::Musicbrainz::Recording.new
          ]
        end

        def initialize_item(query)
          ::Music::Song.new(title: query.title)
        end
      end
    end
  end
end
