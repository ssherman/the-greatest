# frozen_string_literal: true

# Album-specific list item enricher.
# Inherits shared enrichment logic from BaseListItemEnricher.
#
# Searches OpenSearch and MusicBrainz to match list items to albums.
#
module Services
  module Lists
    module Music
      module Albums
        class ListItemEnricher < ::Services::Lists::Music::BaseListItemEnricher
          private

          def opensearch_service_class
            ::Search::Music::Search::AlbumByTitleAndArtists
          end

          def entity_class
            ::Music::Album
          end

          def entity_id_key
            "album_id"
          end

          def entity_name_key
            "album_name"
          end

          def musicbrainz_search_service_class
            ::Music::Musicbrainz::Search::ReleaseGroupSearch
          end

          def musicbrainz_response_key
            "release-groups"
          end

          def musicbrainz_id_key
            "mb_release_group_id"
          end

          def musicbrainz_name_key
            "mb_release_group_name"
          end

          def lookup_existing_by_mb_id(mb_id)
            ::Music::Album.with_musicbrainz_release_group_id(mb_id).first
          end
        end
      end
    end
  end
end
