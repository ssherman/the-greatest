# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Query object for Music::Album import requests
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :artist, :title, :release_group_musicbrainz_id, :primary_albums_only, :options

        def initialize(artist: nil, title: nil, release_group_musicbrainz_id: nil, primary_albums_only: false, **options)
          @artist = artist
          @title = title
          @release_group_musicbrainz_id = release_group_musicbrainz_id
          @primary_albums_only = primary_albums_only
          @options = options
        end

        def valid?
          validation_errors.empty?
        end

        def validate!
          errors = validation_errors
          raise ArgumentError, errors.join(", ") if errors.any?
        end

        private

        UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

        def validation_errors
          errors = []

          # Either artist+title OR release_group_musicbrainz_id is required for single album import
          if release_group_musicbrainz_id.blank?
            if artist.blank?
              errors << "Artist is required when no MusicBrainz Release Group ID is provided"
            end
            if title.blank?
              errors << "Title is required when no MusicBrainz Release Group ID is provided"
            end
          end

          # Validate artist when provided
          if artist.present?
            errors << "Artist must be a Music::Artist" unless artist.is_a?(::Music::Artist)
            errors << "Artist must be persisted" unless artist.persisted?
          end

          # Validate title when provided
          if title.present? && !title.is_a?(String)
            errors << "Title must be a string"
          end

          # Validate MusicBrainz Release Group ID format when provided
          if release_group_musicbrainz_id.present? && !release_group_musicbrainz_id.match?(UUID_REGEX)
            errors << "Release Group MusicBrainz ID must be a valid UUID"
          end

          errors
        end
      end
    end
  end
end
