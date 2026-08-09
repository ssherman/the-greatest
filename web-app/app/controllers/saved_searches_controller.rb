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

  private

  def domain_class
    return @domain_class if defined?(@domain_class)

    @domain_class = SavedSearch.subclass_for(Current.domain)
  end

  def require_domain_support!
    raise ActiveRecord::RecordNotFound if domain_class.nil?
  end
end
