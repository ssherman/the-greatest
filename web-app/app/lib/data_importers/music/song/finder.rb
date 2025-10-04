# frozen_string_literal: true

module DataImporters
  module Music
    module Song
      class Finder < DataImporters::FinderBase
        def call(query:)
          return find_by_musicbrainz_id(query.musicbrainz_recording_id) if query.musicbrainz_recording_id.present?

          find_by_title(query.title)
        end

        private

        def find_by_musicbrainz_id(mbid)
          find_by_identifier(
            identifier_type: :music_musicbrainz_recording_id,
            identifier_value: mbid,
            model_class: ::Music::Song
          )
        end

        def find_by_title(title)
          ::Music::Song.find_by(title: title)
        end
      end
    end
  end
end
