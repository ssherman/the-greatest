class ListableSearchesController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  before_action :prevent_caching
  before_action :require_signed_in!

  # GET /listable_search?listable_type=Music::Album&q=kind+of+blue
  #
  # Signed-in, type-scoped typeahead backing the "add item from list page"
  # search box (02e). Reuses the per-domain OpenSearch autocomplete services via
  # Search::ListableAutocomplete. Unsupported/blank types and blank queries
  # return []. Never cached. The actual add is the 02a items#create endpoint.
  def index
    render json: Search::ListableAutocomplete.search(
      listable_type: params[:listable_type],
      query: params[:q]
    )
  end
end
