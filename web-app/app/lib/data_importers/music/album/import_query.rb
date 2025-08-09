# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Query object for Music::Album import requests
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :artist, :title, :primary_albums_only, :options

        def initialize(artist:, title: nil, primary_albums_only: false, **options)
          @artist = artist
          @title = title
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

        def validation_errors
          errors = []

          errors << "Artist is required" if artist.blank?
          errors << "Artist must be a Music::Artist" unless artist.is_a?(::Music::Artist)
          errors << "Artist must be persisted" unless artist&.persisted?

          if title.present? && !title.is_a?(String)
            errors << "Title must be a string"
          end

          errors
        end
      end
    end
  end
end
