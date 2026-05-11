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
    subclass_names = list_subclasses_for(domain).map(&:name)

    lists = current_user.user_lists.where(type: subclass_names).order(:id).to_a

    items = if lists.any?
      UserListItem.where(user_list_id: lists.map(&:id))
        .pluck(:id, :user_list_id, :listable_type, :listable_id)
    else
      []
    end

    memberships = build_memberships(items)
    ensure_uid_cookie

    render json: {
      version: current_user.updated_at.to_i,
      domain: domain.to_s,
      user_id: current_user.id,
      lists: lists.map { |l| serialize_list(l) },
      memberships: memberships,
      # The cached HTML's <meta name="csrf-token"> belongs to whoever rendered the
      # cache (or no one). Issue a fresh per-session token here for client-side
      # mutations to send back via X-CSRF-Token. This endpoint is never cached.
      csrf_token: form_authenticity_token
    }
  end

  private

  # Maps the current request domain to the STI subclasses whose state should be loaded.
  # Books has no UserList subclass yet; movies/games each have one; music has two.
  def list_subclasses_for(domain)
    case domain
    when :music then [Music::Albums::UserList, Music::Songs::UserList]
    when :games then [Games::UserList]
    when :movies then [Movies::UserList]
    else []
    end
  end

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

  # Backfills the tg_uid cookie for sessions established before the cookie was
  # introduced (or after a manual cookie-clear). Idempotent; setting the same
  # value is a no-op for the browser.
  def ensure_uid_cookie
    return if cookies[AuthController::TG_UID_COOKIE] == current_user.id.to_s
    cookies[AuthController::TG_UID_COOKIE] = {
      value: current_user.id.to_s,
      secure: Rails.env.production?,
      same_site: :lax
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
