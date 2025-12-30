# frozen_string_literal: true

# Song-specific list item enricher.
# Inherits shared enrichment logic from BaseListItemEnricher.
#
# Searches OpenSearch and MusicBrainz to match list items to songs.
#
module Services
  module Lists
    module Music
      module Songs
        class ListItemEnricher < ::Services::Lists::Music::BaseListItemEnricher
          private

          def opensearch_service_class
            ::Search::Music::Search::SongByTitleAndArtists
          end

          def entity_class
            ::Music::Song
          end

          def entity_id_key
            "song_id"
          end

          def entity_name_key
            "song_name"
          end

          def musicbrainz_search_service_class
            ::Music::Musicbrainz::Search::RecordingSearch
          end

          def musicbrainz_response_key
            "recordings"
          end

          def musicbrainz_id_key
            "mb_recording_id"
          end

          def musicbrainz_name_key
            "mb_recording_name"
          end

          def lookup_existing_by_mb_id(mb_id)
            ::Music::Song.with_identifier(:music_musicbrainz_recording_id, mb_id).first
          end
        end
      end
    end
  end
end
