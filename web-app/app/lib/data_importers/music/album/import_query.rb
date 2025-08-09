# frozen_string_literal: true

module DataImporters
  module Music
    module Album
      # Query object for Music::Album import requests
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :artist, :title, :primary_albums_only

        def initialize(artist:, title: nil, primary_albums_only: false, **options)
          @artist = artist
          @title = title
          @primary_albums_only = primary_albums_only
          super(**options)
          validate!
        end

        def valid?
          validate!
          true
        rescue ArgumentError
          false
        end

        private

        def validate!
          errors = []
          
          errors << "Artist is required" if artist.blank?
          errors << "Artist must be a Music::Artist" unless artist.is_a?(::Music::Artist)
          errors << "Artist must be persisted" unless artist&.persisted?
          
          if title.present? && !title.is_a?(String)
            errors << "Title must be a string"
          end

          raise ArgumentError, errors.join(", ") if errors.any?
        end
      end
    end
  end
end