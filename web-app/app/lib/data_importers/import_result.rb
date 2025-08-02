# frozen_string_literal: true

module DataImporters
  # Aggregated results from all providers for an import operation
  class ImportResult
    attr_reader :item, :provider_results, :success

    def initialize(item:, provider_results:, success:)
      @item = item
      @provider_results = Array(provider_results)
      @success = success
    end

    def success?
      @success
    end

    def failure?
      !success?
    end

    def successful_providers
      provider_results.select(&:success?)
    end

    def failed_providers
      provider_results.reject(&:success?)
    end

    def all_errors
      failed_providers.flat_map(&:errors)
    end

    def summary
      {
        success: success?,
        item_saved: item&.persisted? || false,
        providers_run: provider_results.count,
        providers_succeeded: successful_providers.count,
        providers_failed: failed_providers.count,
        data_populated: successful_providers.flat_map(&:data_populated).uniq,
        errors: all_errors
      }
    end
  end
end