# frozen_string_literal: true

module DataImporters
  # Base class for all importers
  # Orchestrates the import process: find existing, create new, run providers, save
  class ImporterBase
    def self.call(query:, force_providers: false)
      new.call(query: query, force_providers: force_providers)
    end

    def call(query:, force_providers: false)
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
        if existing && !force_providers
          return ImportResult.new(
            item: existing,
            provider_results: [],
            success: true
          )
        end

        # Use existing item or create new one
        item = existing || initialize_item(query)

        # Run all providers to populate data, saving after each successful provider
        provider_results = run_providers_with_saving(item, query, existing.present?)

        # Overall success if any provider succeeded
        success = provider_results.any?(&:success?)

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

    def run_providers_with_saving(item, query, is_existing_item)
      provider_results = []

      providers.each do |provider|
        result = provider.populate(item, query: query)
        provider_results << result

        # Save after each successful provider (for new items) or always save for existing items
        if result.success? && item.valid?
          begin
            item.save! if item.changed?
          rescue => e
            Rails.logger.error "Failed to save item after provider #{provider.class.name}: #{e.message}"
            # Convert to failure result
            provider_results[-1] = ProviderResult.failure(
              provider: provider.class.name,
              errors: ["Save failed: #{e.message}"]
            )
          end
        end
      rescue => e
        provider_results << ProviderResult.failure(
          provider: provider.class.name,
          errors: ["Provider error: #{e.message}"]
        )
      end

      provider_results
    end
  end
end
