# frozen_string_literal: true

module DataImporters
  module Music
    module Artist
      # Query object for Music::Artist imports
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :name, :options

        def initialize(name:, **options)
          @name = name
          @options = options
        end

        def valid?
          name.present?
        end

        def to_h
          {
            name: name,
            options: options
          }
        end
      end
    end
  end
end
