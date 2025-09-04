# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Main importer for Music::Album records
      class Importer < DataImporters::ImporterBase
        def self.call(artist: nil, release_group_musicbrainz_id: nil, **options)
          query = ImportQuery.new(artist: artist, release_group_musicbrainz_id: release_group_musicbrainz_id, **options)
          super(query: query)
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
          album = ::Music::Album.new(
            title: query.title
          )
          # Only associate artist if provided (for MusicBrainz ID imports, artists will be set by provider)
          if query.artist.present?
            album.album_artists.build(artist: query.artist, position: 1)
          end
          album
        end
      end
    end
  end
end
