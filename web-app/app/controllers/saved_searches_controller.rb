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
  before_action :require_signed_in!, only: [:index]
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

    result = domain_class.query_class.call(
      # criteria_object, never the raw hash: the readers absorb both the
      # migrated storage shapes and form params. owner:, never current_user:
      # hide_read filters against whoever saved the search, which is what keeps
      # a public search's results stable for its owner (spec §6).
      criteria: @search.criteria_object,
      owner: @search.user,
      page: [params[:page].to_i, 1].max,
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

  private

  def domain_class
    return @domain_class if defined?(@domain_class)

    @domain_class = SavedSearch.subclass_for(Current.domain)
  end

  def require_domain_support!
    raise ActiveRecord::RecordNotFound if domain_class.nil?
  end
end
