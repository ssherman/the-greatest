class Books::GlobalCanonController < ApplicationController
  include Cacheable

  layout "books/application"

  # Above the cache filter on purpose: a 301 must not be decorated with 6-hour
  # public edge-cache headers. find_ranking_configuration runs LAST (mirrors
  # Books::BrowseController): a request headed for a 301 should not pay an
  # uncached default_primary query, and should not risk that lookup turning a
  # clean redirect into a 404 if it ever comes back nil.
  before_action :redirect_to_canonical_form, only: [:show]
  before_action :cache_for_index_page, only: [:show]
  before_action :find_ranking_configuration
  before_action :prevent_caching, only: [:settings, :genres]

  def show
    @settings = Books::GlobalCanonParams.call(params)
    @result = Books::GlobalCanonQuery.call(
      ranking_configuration: @ranking_configuration,
      settings: @settings
    )
    @page_title = "The Global Literary Canon"
    @indexable = @settings.default?
    # No canonical at all on a customised variant. One pointing back at
    # /global-canon would pair noindex with a canonical whose noindex can
    # propagate to the real page -- the rule Books::RankedItemsController
    # states for /rc/ URLs.
    @canonical_path = Books::GlobalCanonPath.call(@settings) if @indexable
  end

  # The settings form's target. Resolves the submitted values and sends the
  # visitor to the canonical path, so the URL grammar lives only in
  # Books::GlobalCanonPath. Mirrors Books::FiltersController#show.
  def settings
    redirect_to Books::GlobalCanonPath.call(Books::GlobalCanonParams.call(params)),
      status: :see_other
  end

  # Search-as-you-type source for the exclusion picker.
  #
  # `{value: slug}`, not the `{value: id}` the saved-search picker uses: this URL
  # grammar is slug-based, and translating ids to slugs in JS would put URL
  # knowledge in two places.
  #
  # types: [:genre] is deliberate and narrower than the books filter modal, which
  # searches genres, subjects AND settings. Excluding "Paris" from a global canon
  # is not a thing this page offers, and GlobalCanonParams 404s such a slug --
  # the endpoint and the validator have to agree.
  def genres
    rows = CategorySearchQuery.call(params[:q], scope: ::Books::Category, types: [:genre])
    render json: rows.map { |category| {value: category.slug, text: category.name} }
  end

  private

  # One rule collapses two non-canonical shapes: a spelled-out set of defaults,
  # and a query string reaching #show. Both compute a canonical path that differs
  # from the request path, so both 301. Comparing against the COMPUTED path
  # rather than testing for query keys means a shape added later is covered for
  # free.
  def redirect_to_canonical_form
    canonical = Books::GlobalCanonPath.call(Books::GlobalCanonParams.call(params))
    return if canonical == request.path

    redirect_to canonical, status: :moved_permanently
  end

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end
end
