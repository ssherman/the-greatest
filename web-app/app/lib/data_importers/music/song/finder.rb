# frozen_string_literal: true

module DataImporters
  module Music
    module Song
      # Finds an existing Music::Song before import and answers with a Match.
      # Increment 1: the pre-redesign lookup (recording MBID, else a bare
      # title match) runs as the single decisive source. Increment 6 replaces
      # it, and retires the title-only fallback, with the real sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Music::Song

        def ranking_configuration_class = ::Music::Songs::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return find_by_musicbrainz_id(query.musicbrainz_recording_id) if query.musicbrainz_recording_id.present?

          find_by_title(query.title)
        end

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
