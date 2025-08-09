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
          validation_errors.empty?
        end

        def validate!
          errors = validation_errors
          raise ArgumentError, errors.join(", ") if errors.any?
        end

        def to_h
          {
            name: name,
            options: options
          }
        end

        private

        def validation_errors
          errors = []
          errors << "Name is required" if name.blank?
          errors << "Name must be a string" unless name.is_a?(String)
          errors
        end
      end
    end
  end
end
