# Admin surface for memberships, including comping.
#
# Admin-only, not admin-or-editor: Admin::BaseController#authenticate_admin!
# admits editors, and billing is money. Same rule and same mechanism as
# Admin::UsersController.
#
# Flat under Admin::, deliberately not nested in an Admin::Billing:: namespace.
# A top-level Billing module already exists (app/sidekiq/billing/), so inside
# Admin::Billing::X a reference to Billing::ProcessStripeEventJob would resolve
# to Admin::Billing::ProcessStripeEventJob and raise. That constant-shadowing
# trap has bitten this codebase three times.
class Admin::MembershipsController < Admin::BaseController
  before_action :require_admin_role!
  before_action :set_membership, only: [:show, :edit, :update, :revoke, :attach]

  def index
    scope = ::Membership.includes(:user, :granted_by)

    # Guarded by the enum's own key set: params[:source] is attacker-controlled,
    # and .key? is false for an Array or an unknown string, so an invalid value
    # is ignored rather than reaching the query.
    scope = scope.where(source: params[:source]) if ::Membership.sources.key?(params[:source])
    scope = scope.where(status: params[:status]) if ::Membership.statuses.key?(params[:status])
    scope = scope.where(user_id: nil) if params[:attached] == "false"

    # to_s first: ?q[]=foo arrives as an Array, and sanitize_sql_like needs a
    # String. Two other controllers on this branch hit the same shape.
    @search_query = params[:q].to_s.presence
    scope = apply_search(scope, @search_query) if @search_query

    @unattached_count = ::Membership.where(user_id: nil).count
    @pagy, @memberships = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end

  def show
  end

  # Placeholder actions. Task 6 replaces every one of these bodies with the real
  # comp / edit / revoke / attach implementations; they exist now only because
  # raise_on_missing_callback_actions validates set_membership's entire :only
  # list on every request, not just the action being served.
  #
  # head :not_implemented, never a bare empty body: an empty non-GET action
  # implicitly renders 204 No Content, which an admin hitting a billing write
  # endpoint would read as success. A billing endpoint that silently does
  # nothing is worse than one that plainly refuses.
  def new = head(:not_implemented)

  def create = head(:not_implemented)

  def edit = head(:not_implemented)

  def update = head(:not_implemented)

  def revoke = head(:not_implemented)

  def attach = head(:not_implemented)

  private

  def apply_search(scope, term)
    pattern = "%#{::User.sanitize_sql_like(term)}%"
    scope.where(
      "memberships.stripe_customer_id ILIKE :p " \
      "OR memberships.stripe_subscription_id ILIKE :p " \
      "OR memberships.user_id IN (SELECT id FROM users WHERE email ILIKE :p OR display_name ILIKE :p)",
      p: pattern
    )
  end

  def set_membership
    @membership = ::Membership.find(params[:id])
  end
end
