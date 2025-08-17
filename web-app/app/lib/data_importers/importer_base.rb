# frozen_string_literal: true

module DataImporters
  # Base class for all importers
  # Orchestrates the import process: find existing, create new, run providers, save
  class ImporterBase
    def self.call(query:)
      new.call(query: query)
    end

    def call(query:)
      validate_query!(query)

      if multi_item_import?
        # For multi-item imports (like releases), providers handle creation
        # Don't use finder to return early - let providers handle existing vs new logic
        provider_results = run_providers(nil, query)

        ImportResult.new(
          item: nil,
          provider_results: provider_results,
          success: provider_results.any?(&:success?)
        )
      else
        # Standard single-item import flow
        # Try to find existing record
        existing = finder.call(query: query)
        return existing if existing

        # Initialize new record
        item = initialize_item(query)

        # Run all providers to populate data
        provider_results = run_providers(item, query)

        # Save if valid and any provider succeeded
        success = save_item_if_valid(item, provider_results)

        # Return aggregated results
        ImportResult.new(
          item: item,
          provider_results: provider_results,
          success: success
        )
      end
    end

    protected

    def validate_query!(query)
      unless query.respond_to?(:valid?) && query.valid?
        raise ArgumentError, "Invalid query object"
      end
    end

    def finder
      raise NotImplementedError, "Subclasses must implement #finder"
    end

    def providers
      raise NotImplementedError, "Subclasses must implement #providers"
    end

    def initialize_item(query)
      raise NotImplementedError, "Subclasses must implement #initialize_item(query)" unless multi_item_import?
    end

    # Override in subclasses that import multiple items (like releases)
    # Default is false for single-item imports (artists, albums)
    def multi_item_import?
      false
    end

    def run_providers(item, query)
      providers.map do |provider|
        provider.populate(item, query: query)
      rescue => e
        ProviderResult.failure(
          provider: provider.class.name,
          errors: ["Provider error: #{e.message}"]
        )
      end
    end

    def save_item_if_valid(item, provider_results)
      return false unless item.valid?
      return false unless provider_results.any?(&:success?)

      item.save!
      true
    rescue => e
      Rails.logger.error "Failed to save imported item: #{e.message}"
      false
    end
  end
end
