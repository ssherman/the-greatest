# frozen_string_literal: true

module DataImporters
  # Represents the result of a single provider's import attempt
  class ProviderResult
    attr_reader :provider_name, :success, :data_populated, :errors

    def initialize(provider_name:, success:, data_populated: [], errors: [])
      @provider_name = provider_name
      @success = success
      @data_populated = Array(data_populated)
      @errors = Array(errors)
    end

    def self.success(provider:, data_populated: [])
      new(
        provider_name: provider,
        success: true,
        data_populated: data_populated
      )
    end

    def self.failure(provider:, errors:)
      new(
        provider_name: provider,
        success: false,
        errors: Array(errors)
      )
    end

    def success?
      @success
    end

    def failure?
      !success?
    end
  end
end