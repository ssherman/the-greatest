class UserListStateController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  # State endpoint must never be cached at CloudFlare or in the browser.
  before_action :prevent_caching
  before_action :require_signed_in!

  # GET /user_list_state
  # Returns the signed-in user's lists + memberships scoped to Current.domain.
  # See docs/specs/user-lists-02a-add-to-list-widget.md for the response schema.
  def show
    domain = Current.domain
    subclass_names = UserList.subclasses_for(domain).map(&:name)

    lists = Services::UserLists::EnsureDefaults.call(
      user: current_user,
      domain: domain,
      existing: current_user.user_lists.where(type: subclass_names).order(:id).to_a
    ).sort_by(&:id)

    items = if lists.any?
      UserListItem.where(user_list_id: lists.map(&:id))
        .pluck(:id, :user_list_id, :listable_type, :listable_id)
    else
      []
    end

    memberships = build_memberships(items)
    # Runs before the freshness check: a 304 is still a request from a live
    # session, and skipping this would let a tab that only re-checks expire.
    renew_current_session

    membership = current_user.granting_membership

    # Everything that identifies the user's state, and nothing that varies per
    # request. The ETag digests this, so the CSRF token (fresh per session) and
    # version (updated_at, bumped by writes that change nothing shown here) stay
    # out of it. Membership expiry changes the payload with no row write;
    # reading granting_membership at request time is what covers it.
    payload = {
      domain: domain.to_s,
      user_id: current_user.id,
      lists: lists.map { |l| serialize_list(l) },
      memberships: memberships,
      membership: {
        member: membership.present?,
        # nil for a comp or a legacy grant: they have no billing interval.
        plan: membership&.interval,
        source: membership&.source,
        # nil means "never expires", not "expired".
        current_period_end: membership&.current_period_end&.iso8601
      }
    }

    # stale? strips no-store that prevent_caching set, so restate it here.
    return unless stale?(etag: payload, cache_control: {no_store: true, private: true})

    render json: payload.merge(
      version: current_user.updated_at.to_i,
      # The cached HTML's <meta name="csrf-token"> belongs to whoever rendered the
      # cache (or no one). Issue a fresh per-session token here for client-side
      # mutations to send back via X-CSRF-Token. This endpoint is never cached.
      csrf_token: form_authenticity_token
    )
  end

  private

  def serialize_list(list)
    icon_key = list.list_type.to_sym
    {
      id: list.id,
      type: list.class.name,
      list_type: list.list_type,
      name: list.name,
      default: list.default?,
      icon: list.class.list_type_icons[icon_key]
    }
  end

  # Shape: { listable_type => { listable_id (string) => [{list_id, item_id}, ...] } }
  # The item_id is needed so the modal can DELETE the underlying UserListItem
  # when a checkbox is unticked, without an extra round-trip to look it up.
  def build_memberships(items)
    items.each_with_object({}) do |(item_id, list_id, listable_type, listable_id), acc|
      acc[listable_type] ||= {}
      acc[listable_type][listable_id.to_s] ||= []
      acc[listable_type][listable_id.to_s] << {list_id: list_id, item_id: item_id}
    end
  end
end
