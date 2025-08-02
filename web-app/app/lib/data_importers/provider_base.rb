# frozen_string_literal: true

module DataImporters
  # Base class for all data providers (MusicBrainz, TMDB, etc.)
  # Each provider knows how to populate data from its specific external source
  class ProviderBase
    def populate(item, query:)
      raise NotImplementedError, "Subclasses must implement #populate(item, query:)"
    end

    protected

    def success_result(data_populated: [])
      ProviderResult.success(
        provider: self.class.name,
        data_populated: data_populated
      )
    end

    def failure_result(errors:)
      ProviderResult.failure(
        provider: self.class.name,
        errors: errors
      )
    end
  end
end