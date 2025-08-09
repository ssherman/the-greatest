# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Main importer for Music::Album records
      class Importer < DataImporters::ImporterBase
        def self.call(artist:, **options)
          query = ImportQuery.new(artist: artist, **options)
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

        def initialize_item(query)
          ::Music::Album.new(
            title: query.title,
            primary_artist: query.artist
          )
        end
      end
    end
  end
end