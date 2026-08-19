class Books::GlobalCanonController < ApplicationController
  include Cacheable

  layout "books/application"

  # Above the cache filter on purpose: a 301 must not be decorated with 6-hour
  # public edge-cache headers. find_ranking_configuration runs LAST (mirrors
  # Books::BrowseController): a request headed for a 301 should not pay an
  # uncached default_primary query, and should not risk that lookup turning a
  # clean redirect into a 404 if it ever comes back nil.
  #
  # find_ranking_configuration is scoped to :show ONLY -- it is the only
  # action that reads @ranking_configuration. #settings never touches it
  # (Books::GlobalCanonPath/Params are all it needs), and #genres is the
  # exclusion picker's search-as-you-type source, firing on every keystroke:
  # running an uncached default_primary lookup there was a wasted query per
  # keystroke, and a nil RC would 404 the JSON endpoint for a reason that has
  # nothing to do with it. Scoping it away from :genres also means
  # prevent_caching is the only filter left on that action, so its no-store
  # header can never be skipped by a 404 raised earlier in the chain.
  before_action :redirect_to_canonical_form, only: [:show]
  before_action :cache_for_index_page, only: [:show]
  before_action :find_ranking_configuration, only: [:show]
  before_action :prevent_caching, only: [:settings, :genres]

  # Mirrors Books::BrowseController::QUERY_FORM_KEYS. These are the only
  # query keys #show ever resolves into a Settings; a query carrying none of
  # them (utm_source, fbclid, ...) must stay a 200 -- redirecting those away
  # destroys campaign attribution.
  QUERY_FORM_KEYS = %w[total_books nonfiction_percentage max_books_per_country excluded_genres].freeze

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

  # Comparing the COMPUTED path against the request path catches a
  # spelled-out set of defaults and a query string that resolves to
  # NON-default settings -- both compute a canonical path that differs from
  # request.path, which excludes the query string entirely. It does NOT catch
  # a query string that resolves to the DEFAULT settings (e.g.
  # ?total_books=150): the computed canonical is the bare path, which is
  # already request.path, so the comparison alone sees no difference and would
  # serve a publicly-cacheable 200 under a URL Cloudflare mints a fresh cache
  # entry for on every distinct query string.
  #
  # The QUERY_FORM_KEYS check closes that gap, mirroring
  # Books::BrowseController: any RECOGNIZED key present in the query string
  # forces the redirect regardless of what it resolves to. Only recognized
  # keys count -- utm_source, fbclid and friends must keep returning 200, so
  # this checks for specific keys, never bare query-string presence.
  #
  # request.query_parameters, NOT params, for that check -- same reasoning as
  # Books::BrowseController: on a routed path like
  # /global-canon/total_books/250/... the same values arrive as PATH
  # parameters (in params), and triggering off params would make every such
  # request redirect to itself forever. request.query_parameters only ever
  # holds the literal `?...` query string, so a routed path with no query
  # string never trips this check.
  #
  # Termination: /global-canon?total_books=150 has "total_books" in
  # query_parameters, so it redirects to the computed canonical ("/global-canon",
  # since 150 is the default). That target carries no query string, so on the
  # next request query_parameters.slice(...) is empty and canonical ==
  # request.path -- no redirect, a plain 200.
  def redirect_to_canonical_form
    canonical = Books::GlobalCanonPath.call(Books::GlobalCanonParams.call(params))
    return if canonical == request.path && request.query_parameters.slice(*QUERY_FORM_KEYS).empty?

    redirect_to canonical, status: :moved_permanently
  end

  def find_ranking_configuration
    @ranking_configuration = Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if @ranking_configuration.nil?
  end
end
