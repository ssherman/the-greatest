# frozen_string_literal: true

# Per-user membership state for pages that are cached at the edge and therefore
# render identical HTML for everyone. Same shape and same rules as
# UserListStateController and ReviewStateController.
class MembershipStateController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  before_action :prevent_caching
  before_action :require_signed_in!

  # GET /membership_state
  def show
    membership = current_user.granting_membership

    render json: {
      member: membership.present?,
      # nil for a comp or a legacy grant: they have no billing interval.
      plan: membership&.interval,
      source: membership&.source,
      # nil means "never expires", not "expired" -- the client must not treat a
      # null date as a lapsed membership.
      current_period_end: membership&.current_period_end&.iso8601,
      # The cached HTML's <meta name="csrf-token"> belongs to whoever rendered
      # the cache (or no one). Issue a fresh per-session token here for
      # client-side mutations to send back via X-CSRF-Token.
      csrf_token: form_authenticity_token
    }
  end
end
