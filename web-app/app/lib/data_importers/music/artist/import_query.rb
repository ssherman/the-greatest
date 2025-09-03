# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      # Query object for Music::Artist imports
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :name, :musicbrainz_id, :options

        def initialize(name: nil, musicbrainz_id: nil, **options)
          @name = name
          @musicbrainz_id = musicbrainz_id
          @options = options
        end

        def valid?
          validation_errors.empty?
        end

        def validate!
          errors = validation_errors
          raise ArgumentError, errors.join(", ") if errors.any?
        end

        def to_h
          {
            name: name,
            musicbrainz_id: musicbrainz_id,
            options: options
          }
        end

        private

        def validation_errors
          errors = []

          # Either name OR musicbrainz_id is required
          if name.blank? && musicbrainz_id.blank?
            errors << "Either name or musicbrainz_id is required"
          end

          # Validate name if provided
          if name.present?
            errors << "Name must be a string" unless name.is_a?(String)
          end

          # Validate musicbrainz_id if provided
          if musicbrainz_id.present?
            errors << "MusicBrainz ID must be a string" unless musicbrainz_id.is_a?(String)
            errors << "MusicBrainz ID must be a valid UUID format" unless valid_uuid?(musicbrainz_id)
          end

          errors
        end

        def valid_uuid?(uuid)
          uuid_pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
          uuid.match?(uuid_pattern)
        end
      end
    end
  end
end
