# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      # Finds an existing Music::Artist before import and answers with a Match.
      # Increment 1: the pre-redesign lookup (MBID, else a MusicBrainz name
      # search resolved to a local MBID, else exact name) runs as the single
      # decisive source. Increment 6 replaces it with the real sources.
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Music::Artist

        def ranking_configuration_class = ::Music::Artists::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          return find_existing_item(query) if query.musicbrainz_id.present?

          find_existing_item_by_name(query)
        end

        def find_existing_item(query)
          # Direct lookup by MusicBrainz ID if provided
          find_by_musicbrainz_id(query.musicbrainz_id)
        end

        def find_existing_item_by_name(query)
          # First, search MusicBrainz to get the MBID for this artist
          search_result = search_musicbrainz(query.name)

          if search_result[:success] && search_result[:data]["artists"].any?
            mbid = search_result[:data]["artists"].first["id"]

            # Try to find existing artist by MusicBrainz ID (most reliable)
            existing = find_by_musicbrainz_id(mbid)
            return existing if existing
          end

          # Fallback: try to find by exact name match
          existing = find_by_name(query.name)
          return existing if existing

          # For now, skip AI-assisted matching - will add later
          # TODO: Add AI-assisted matching for ambiguous cases

          nil
        end

        def search_musicbrainz(name)
          search_service.search_by_name(name)
        rescue => e
          Rails.logger.warn "MusicBrainz search failed in finder: #{e.message}"
          {success: false, errors: [e.message]}
        end

        def search_service
          @search_service ||= ::Music::Musicbrainz::Search::ArtistSearch.new
        end

        def find_by_musicbrainz_id(mbid)
          find_by_identifier(
            identifier_type: :music_musicbrainz_artist_id,
            identifier_value: mbid,
            model_class: ::Music::Artist
          )
        end

        def find_by_name(name)
          ::Music::Artist.find_by(name: name)
        end

        # Future: AI-assisted matching will go here
        # def find_with_ai_assistance(name)
        #   # Use AI to match against similar artist names
        # end
      end
    end
  end
end
