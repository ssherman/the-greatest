# frozen_string_literal: true

module DataImporters
  module Music
    module Song
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :title, :musicbrainz_recording_id, :options

        def initialize(title: nil, musicbrainz_recording_id: nil, **options)
          @title = title
          @musicbrainz_recording_id = musicbrainz_recording_id
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
            title: title,
            musicbrainz_recording_id: musicbrainz_recording_id,
            options: options
          }
        end

        private

        def validation_errors
          errors = []

          if title.blank? && musicbrainz_recording_id.blank?
            errors << "Either title or musicbrainz_recording_id is required"
          end

          if title.present?
            errors << "Title must be a string" unless title.is_a?(String)
          end

          if musicbrainz_recording_id.present?
            errors << "MusicBrainz recording ID must be a string" unless musicbrainz_recording_id.is_a?(String)
            if musicbrainz_recording_id.is_a?(String)
              errors << "MusicBrainz recording ID must be a valid UUID format" unless valid_uuid?(musicbrainz_recording_id)
            end
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
