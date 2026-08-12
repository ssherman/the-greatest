# frozen_string_literal: true

module Books
  # Searches languages by name for the saved-search form's picker. Mirrors
  # Books::CountrySearchQuery's shape (blank-query-returns-empty,
  # case-insensitive substring, limit) so the two boxes behave identically.
  #
  # Language is a shared model, not Books::Language -- books is just the only
  # domain that stores language criteria today, the same reason
  # SavedSearch#category_class points at ::Books::Category rather than a
  # domain-neutral class existing yet.
  class LanguageSearchQuery
    DEFAULT_LIMIT = 10

    def self.call(query, limit: DEFAULT_LIMIT)
      new(query, limit: limit).call
    end

    def initialize(query, limit:)
      @query = query.to_s.strip
      @limit = limit
    end

    def call
      return [] if @query.blank?

      ::Language
        .search_by_name(@query)
        .order(:name)
        .limit(@limit)
        .to_a
    end
  end
end
