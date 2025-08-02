# frozen_string_literal: true

module DataImporters
  # Base class for finding existing records before import
  # Uses external identifiers and intelligent matching
  class FinderBase
    def call(query:)
      raise NotImplementedError, "Subclasses must implement #call(query:)"
    end

    protected

    # Find existing record by external identifier
    def find_by_identifier(identifier_type:, identifier_value:, model_class:)
      identifier = Identifier.find_by(
        identifier_type: identifier_type,
        value: identifier_value,
        identifiable_type: model_class.name
      )

      identifier&.identifiable
    end
  end
end
