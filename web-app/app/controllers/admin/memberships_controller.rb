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

  # Stub actions -- Task 6 implements these for real. They exist as bare
  # public methods only so Rails' raise_on_missing_callback_actions (the 7.1
  # default, and explicitly on in both test.rb and development.rb here) does
  # not reject the :set_membership before_action's :only list above: that
  # check validates every action named in :only on every request to this
  # controller, not just the one being dispatched, regardless of which action
  # is currently running.
  def new
  end

  def edit
  end

  def create
  end

  def update
  end

  def revoke
  end

  def attach
  end

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
