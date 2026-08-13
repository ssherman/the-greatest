# frozen_string_literal: true

module SavedSearches
  # JSON country search for the saved-search form's picker. Same shape and
  # guards as CategoriesController: signed-in only, 404s on a host with no
  # SavedSearch subclass, never cached.
  #
  # The {value:, text:} shape matches CategoriesController, so one Stimulus
  # controller (saved-search-picker) drives all three taxonomy pickers.
  #
  # Resolved through domain_class.country_search_query_class rather than
  # calling Books::CountrySearchQuery directly, so this controller stays
  # domain-generic -- the same reason CategoriesController resolves through
  # domain_class.category_class instead of naming ::Books::Category.
  class CountriesController < ApplicationController
    include Cacheable
    include SavedSearchDomainScoped

    LIMIT = 10

    before_action :require_domain_support!
    before_action :require_signed_in!
    before_action :prevent_caching

    def index
      countries = domain_class.country_search_query_class.call(params[:q], limit: LIMIT)

      render json: countries.map { |c| {value: c.id, text: c.name} }
    end
  end
end
