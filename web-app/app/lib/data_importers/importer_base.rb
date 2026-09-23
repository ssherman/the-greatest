# frozen_string_literal: true

module DataImporters
  # Base class for all importers
  # Orchestrates the import process: find existing, create new, run providers, save
  class ImporterBase
    def self.call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
      new.call(query: query, item: item, force_providers: force_providers, providers: providers, subject: subject, verify: verify)
    end

    def call(query: nil, item: nil, force_providers: false, providers: nil, subject: nil, verify: false)
      # Validate input parameters
      if item.nil? && query.nil?
        raise ArgumentError, "Either item or query must be provided"
      end

      if item.present? && query.present?
        raise ArgumentError, "Cannot specify both item and query - use one or the other"
      end

      # Validate query if provided
      validate_query!(query) if query.present?

      if multi_item_import?
        # For multi-item imports (like releases), providers handle creation
        # Item parameter not supported for multi-item imports
        if item.present?
          raise ArgumentError, "Item parameter not supported for multi-item imports"
        end

        # Don't use finder to return early - let providers handle existing vs new logic
        provider_results = run_providers(nil, query, providers)

        ImportResult.new(
          item: nil,
          provider_results: provider_results,
          success: provider_results.any?(&:success?)
        )
      else
        match = nil

        # Determine the item to work with
        if item.present?
          # Item-based import: use provided item
          target_item = item
          is_existing_item = true
        else
          # Query-based import: ask the finder. It always answers, and records
          # the answer; `match.record` is nil when nothing matched.
          match = finder.call(query: query, verify: verify, subject: subject)
          existing = match.record
          if existing && !force_providers
            return ImportResult.new(
              item: existing,
              provider_results: [],
              success: true,
              match: match
            )
          end

          # Use existing item or create new one
          target_item = existing || initialize_item(query)
          is_existing_item = existing.present?
        end

        # Run providers to populate data, saving after each successful provider
        provider_results = run_providers_with_saving(target_item, query, is_existing_item, providers, match: match)

        # A new record now exists: point the finder's decision at it.
        if match && !is_existing_item && target_item.persisted?
          match.decision&.update!(record: target_item)
        end

        # Overall success if any provider succeeded
        success = provider_results.any?(&:success?)

        # Return aggregated results
        ImportResult.new(
          item: target_item,
          provider_results: provider_results,
          success: success,
          match: match
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

    def run_providers(item, query, selected_providers = nil, match: nil)
      target_providers = filter_providers(selected_providers)

      target_providers.map do |provider|
        provider.populate(item, query: query, match: match)
      rescue => e
        ProviderResult.failure(
          provider: provider.class.name,
          errors: ["Provider error: #{e.message}"]
        )
      end
    end

    def run_providers_with_saving(item, query, is_existing_item, selected_providers = nil, match: nil)
      provider_results = []
      target_providers = filter_providers(selected_providers)

      target_providers.each do |provider|
        result = provider.populate(item, query: query, match: match)
        provider_results << result

        # Save after each successful provider to persist both attribute changes and associations
        if result.success? && item.valid?
          begin
            item.save!
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

    # Filter providers based on selective execution
    def filter_providers(selected_providers)
      if selected_providers.present?
        # Convert symbols to class names for comparison
        selected_names = selected_providers.map do |provider_name|
          if provider_name.is_a?(Symbol)
            # Convert :amazon to "Amazon", :music_brainz to "MusicBrainz"
            provider_name.to_s.split("_").map(&:capitalize).join
          else
            provider_name.to_s
          end
        end

        # Filter providers by class name
        providers.select do |provider|
          provider_class_name = provider.class.name.split("::").last
          selected_names.include?(provider_class_name)
        end
      else
        # Use all providers if none specified
        providers
      end
    end
  end
end
