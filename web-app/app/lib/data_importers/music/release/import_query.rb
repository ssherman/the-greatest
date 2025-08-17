# frozen_string_literal: true

module DataImporters
  module Music
    module Release
      class ImportQuery
        attr_reader :album

        def initialize(album:)
          @album = album
        end

        def valid?
          album.present? && album.is_a?(::Music::Album) && album.persisted?
        end

        def validate!
          raise ArgumentError, "Album is required" unless album.present?
          raise ArgumentError, "Album must be a Music::Album" unless album.is_a?(::Music::Album)
          raise ArgumentError, "Album must be persisted" unless album&.persisted?
        end
      end
    end
  end
end
