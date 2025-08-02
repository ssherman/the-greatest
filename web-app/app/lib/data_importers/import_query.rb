# frozen_string_literal: true

module DataImporters
  # Base class for all import query objects
  # Provides structure for domain-specific import parameters
  class ImportQuery
    def self.build(type:, **params)
      case type
      when :artist then Music::Artist::ImportQuery.new(**params)
      # Future: when :book then Books::Book::ImportQuery.new(**params)
      # Future: when :movie then Movies::Movie::ImportQuery.new(**params)
      # Future: when :game then Games::Game::ImportQuery.new(**params)
      else
        raise ArgumentError, "Unknown import type: #{type}"
      end
    end

    def valid?
      raise NotImplementedError, "Subclasses must implement #valid?"
    end
  end
end
