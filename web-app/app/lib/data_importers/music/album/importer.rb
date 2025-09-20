# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Main importer for Music::Album records
      class Importer < DataImporters::ImporterBase
        def self.call(artist: nil, release_group_musicbrainz_id: nil, item: nil, force_providers: false, providers: nil, **options)
          if item.present?
            # Item-based import: use existing album
            super(item: item, force_providers: force_providers, providers: providers)
          else
            # Query-based import: create query object
            query = ImportQuery.new(artist: artist, release_group_musicbrainz_id: release_group_musicbrainz_id, **options)
            super(query: query, force_providers: force_providers, providers: providers)
          end
        end

        protected

        def finder
          @finder ||= Finder.new
        end

        def providers
          @providers ||= [
            Providers::MusicBrainz.new,
            Providers::Amazon.new
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
