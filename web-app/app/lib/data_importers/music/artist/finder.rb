# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      # Finds existing Music::Artist records before import
      class Finder < DataImporters::FinderBase
        def call(query:)
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

        private

        def search_musicbrainz(name)
          search_service.search_by_name(name)
        rescue => e
          Rails.logger.warn "MusicBrainz search failed in finder: #{e.message}"
          { success: false, errors: [e.message] }
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