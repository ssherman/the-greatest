# frozen_string_literal: true

module DataImporters
  module Games
    module Company
      # Query object for Games::Company imports
      # Validates that igdb_id is provided and valid
      class ImportQuery < DataImporters::ImportQuery
        attr_reader :igdb_id, :options

        def initialize(igdb_id: nil, **options)
          @igdb_id = igdb_id
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
            igdb_id: igdb_id,
            options: options
          }
        end

        private

        def validation_errors
          errors = []

          # igdb_id is required
          if igdb_id.blank?
            errors << "igdb_id is required"
          elsif !igdb_id.is_a?(Integer)
            errors << "igdb_id must be an integer"
          elsif igdb_id < 1
            errors << "igdb_id must be a positive integer"
          end

          errors
        end
      end
    end
  end
end
