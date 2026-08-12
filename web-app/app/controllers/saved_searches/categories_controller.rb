# frozen_string_literal: true

module SavedSearches
  # JSON category search for the saved-search form's picker. Signed-in only,
  # and 404s on a host with no SavedSearch subclass, matching
  # SavedSearchesController's own guards.
  #
  # The {value:, text:} shape matches the admin autocomplete, so the picker and
  # every admin category select consume the same contract.
  #
  # Never cached, matching every other saved-search endpoint: this is signed-in
  # only, and the header SavedSearchesController states for the whole feature
  # ("Never cached") has to hold for the endpoint the form fetches from too.
  class CategoriesController < ApplicationController
    include Cacheable
    include SavedSearchDomainScoped

    LIMIT = 10

    before_action :require_domain_support!
    before_action :require_signed_in!
    before_action :prevent_caching

    def index
      categories = CategorySearchQuery.call(
        params[:q],
        scope: domain_class.category_class,
        limit: LIMIT
      )

      render json: categories.map { |c| {value: c.id, text: c.name_with_type} }
    end
  end
end
