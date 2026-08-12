# Saved searches, ported from the legacy books site (spec
# 2026-08-08-books-saved-searches-design.md). Global routes, no
# DomainConstraint: Current.domain picks the STI subclass, so games gets
# /searches on its own host later without a new controller.
#
# index is owner-only. show serves the owner or any viewer -- including
# anonymous -- when the search is public, and 404s everything else through
# SavedSearch.visible_to rather than 403ing, which would confirm the id exists.
#
# Never cached: these pages are per-user AND write last_executed_at on read.
class SavedSearchesController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination
  include DomainLayout

  # Fixed, with no ?limit= escape hatch -- legacy honoured one, which makes the
  # page space unbounded. 50 also divides OpenSearch's 10,000-result window
  # exactly, so the last reachable page is full rather than short (spec §5.4).
  PER_PAGE = 50

  layout :resolve_layout

  # Before require_signed_in!, so /searches on a host with no saved searches
  # 404s instead of bouncing an anonymous visitor to a sign-in that would not
  # have helped.
  before_action :require_domain_support!
  before_action :require_signed_in!, only: [:index, :new, :create, :edit, :update, :destroy]
  before_action :set_owned_search, only: [:edit, :update, :destroy]
  before_action :load_taxonomies, only: [:new, :create, :edit, :update]
  before_action :prevent_caching

  # GET /searches(/page/:page)
  def index
    @pagy, @searches = pagy_path(
      domain_class.owned_by(current_user).by_last_executed.by_created,
      limit: PER_PAGE
    )
  end

  # GET /searches/:id(/page/:page)
  #
  # Reachable anonymously for a public search. Scoped through visible_to, which
  # 404s a private search for anyone but its owner -- Pundit's rescue would
  # redirect, confirming the id exists.
  def show
    @search = domain_class.visible_to(current_user).find(params[:id])
    authorize @search, :show?, policy_class: SavedSearchPolicy
    @owner = @search.user_id == current_user&.id

    page = [params[:page].to_i, 1].max

    # Two bounds checks guard this action, and neither replaces the other.
    # This one runs BEFORE the query: OpenSearch cannot serve anything past
    # `from + size = MAX_RESULT_WINDOW`, so a page beyond
    # query_class.max_page is unreachable by construction (10,000 / 50 =
    # 200), and can 404 at constant cost instead of paying for a full
    # OpenSearch query it can only discard. pagy_path_count below is the
    # other one: it catches a page that IS inside the window but past the
    # end of a small result set, which still needs the query to run once to
    # learn the real total.
    raise ActiveRecord::RecordNotFound if page > domain_class.query_class.max_page(per_page: PER_PAGE)

    result = domain_class.query_class.call(
      # criteria_object, never the raw hash: the readers absorb both the
      # migrated storage shapes and form params. owner:, never current_user:
      # hide_read filters against whoever saved the search, which is what keeps
      # a public search's results stable for its owner (spec §6).
      criteria: @search.criteria_object,
      owner: @search.user,
      page: page,
      per_page: PER_PAGE
    )

    # Before the last_executed_at write: this raises RecordNotFound past the
    # last page, and a 404 is not an execution.
    @pagy = pagy_path_count(result.total, limit: PER_PAGE)
    @books = result.books
    @total_capped = result.capped?
    @filter_groups = domain_class.filter_labels_class.call(@search.criteria_object)

    # A write on a read, and the only one in the app. It drives the index
    # page's default ordering. update_column so a read never bumps updated_at
    # and no callback fires. Legacy recorded this for any viewer, including a
    # stranger reading a public search; that is preserved.
    @search.update_column(:last_executed_at, Time.current)
  end

  # GET /searches/new
  def new
    @search = domain_class.new(user: current_user, criteria: {})
    authorize @search, :new?, policy_class: SavedSearchPolicy
  end

  # POST /searches
  def create
    @search = domain_class.new(saved_search_params)
    @search.user = current_user
    @search.criteria = criteria_params
    authorize @search, :create?, policy_class: SavedSearchPolicy

    if @search.save
      redirect_to saved_search_path(@search), notice: "Search saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /searches/:id/edit
  def edit
  end

  # PATCH/PUT /searches/:id
  def update
    @search.assign_attributes(saved_search_params)
    @search.criteria = criteria_params if params[:saved_search].key?(:criteria)

    if @search.save
      redirect_to saved_search_path(@search), notice: "Search updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /searches/:id
  def destroy
    @search.destroy
    redirect_to saved_searches_path, notice: "Search deleted.", status: :see_other
  end

  private

  def domain_class
    return @domain_class if defined?(@domain_class)

    @domain_class = SavedSearch.subclass_for(Current.domain)
  end

  def require_domain_support!
    raise ActiveRecord::RecordNotFound if domain_class.nil?
  end

  # Ordered by name so the two multi-selects are scannable. Loaded for create
  # and update too, because both re-render the form on a validation failure.
  #
  # ::Books::Country is books-specific in a domain-generic controller. That is
  # acceptable only because this increment ships one domain; when games
  # arrives, move both loads behind a `domain_class.taxonomies_for_form` hook
  # rather than adding a conditional here.
  def load_taxonomies
    @languages = Language.order(:name)
    @countries = ::Books::Country.order(:name)
  end

  # Scoped to the owner, so a stranger gets RecordNotFound -- a 404, not the
  # 403 Pundit would raise, which would confirm the id exists (spec §8).
  # authorize still runs: the scope is the security boundary, the policy is the
  # statement of intent, and Pundit's verify_authorized would flag its absence.
  def set_owned_search
    @search = domain_class.owned_by(current_user).find(params[:id])
    authorize @search, :"#{action_name}?", policy_class: SavedSearchPolicy
  end

  def saved_search_params
    params.require(:saved_search).permit(:name, :description, :public)
  end

  # Permitted explicitly rather than with `criteria: {}` -- a bare hash permit
  # would store whatever the form posted, including keys no reader knows.
  def criteria_params
    domain_class.criteria_params_class.call(
      params.require(:saved_search).fetch(:criteria, nil)&.permit(
        :book_type, :ranked, :hide_read, :genre_match_mode,
        :first_year_published_gt, :first_year_published_lt, :max_ranked_position,
        book_length: [],
        included_category_ids: [], excluded_category_ids: [],
        included_language_ids: [], excluded_language_ids: [],
        included_country_ids: [], excluded_country_ids: []
      )
    )
  end
end
