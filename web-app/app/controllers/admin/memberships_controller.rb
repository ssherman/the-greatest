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

  def new
    @membership = ::Membership.new
  end

  def create
    user = ::User.find_by(id: comp_params[:user_id])
    if user.nil?
      @membership = ::Membership.new(comp_params)
      flash.now[:alert] = "No user with that id."
      render :new, status: :unprocessable_entity
      return
    end

    membership = ::Membership.find_or_initialize_by(user_id: user.id, source: :comped)
    membership.assign_attributes(
      status: :active,
      # Mirrors Services::BooksMigration::MembershipMigrator#upsert_row: a
      # revoke sets canceled_at, and find_or_initialize_by re-fetches that same
      # row, so re-comping it must clear canceled_at explicitly or the row ends
      # up active with a stale cancellation timestamp still on it.
      canceled_at: nil,
      current_period_end: comp_params[:current_period_end].presence,
      note: comp_params[:note].presence,
      # From the session, never from params. An admin must not be able to
      # record someone else as the person who authorised a comp.
      granted_by_id: current_user.id
    )

    if membership.save
      redirect_to admin_membership_path(membership), notice: "Membership comped."
    else
      @membership = membership
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # Only reachable if two admins comp the same user at the same moment --
    # find_or_initialize_by handles the ordinary repeat. The (user_id, source)
    # index is what turns the race into this instead of a duplicate row.
    redirect_to admin_memberships_path, alert: "That user already has a comped membership."
  end

  def edit
    return if editable?
    redirect_to admin_membership_path(@membership), alert: stripe_owned_message
  end

  def update
    unless editable?
      redirect_to admin_membership_path(@membership), alert: stripe_owned_message
      return
    end

    attributes = edit_params.to_h.symbolize_keys
    # An empty date field means "never expires", not "leave it alone".
    attributes[:current_period_end] = attributes[:current_period_end].presence if attributes.key?(:current_period_end)

    if @membership.update(attributes)
      redirect_to admin_membership_path(@membership), notice: "Membership updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def revoke
    unless editable?
      redirect_to admin_membership_path(@membership), alert: "Cancel a Stripe subscription in Stripe, not here."
      return
    end

    # Status and a passed end date, not destroy: the note and granted_by are the
    # audit trail for why access was given, and deleting the row throws that
    # away. Membership.granting_access is designed to deny a non-Stripe row
    # whose current_period_end has passed, which is what will make this end
    # access immediately -- but that method ships with the entitlements
    # increment and does not exist yet, so nothing in the app currently reads
    # memberships to grant or deny access at all. See "Known limits" in
    # docs/features/membership-billing.md.
    @membership.update!(status: :canceled, canceled_at: Time.current, current_period_end: Time.current)
    redirect_to admin_membership_path(@membership), notice: "Membership revoked."
  end

  def attach
    if @membership.user_id.present?
      redirect_to admin_membership_path(@membership), alert: "Already attached to a user."
      return
    end

    # An explicit user id, never an email match. Inferring identity from an
    # email address is how one person is handed another person's paid
    # membership; an admin looking at both records makes the call instead.
    #
    # to_s first: user_id[]=42&user_id[]=99 arrives as an Array, and without
    # coercion find_by(id: [...]) becomes a WHERE id IN (...) LIMIT 1 --
    # attaching to whichever row Postgres happens to return first. Same shape
    # as params[:q].to_s elsewhere in this controller.
    user = ::User.find_by(id: params[:user_id].to_s)
    if user.nil?
      redirect_to admin_membership_path(@membership), alert: "No user with that id."
      return
    end

    ::Membership.transaction do
      @membership.update!(user: user)
      # Makes the link durable: ReconcileCustomer resolves a user by
      # users.stripe_customer_id first, so writing it means the next reconcile
      # finds this customer without help. Only when blank -- users
      # .stripe_customer_id has a non-unique index, and overwriting an existing
      # value would silently repoint whichever customer was there before.
      if user.stripe_customer_id.blank? && @membership.stripe_customer_id.present?
        user.update!(stripe_customer_id: @membership.stripe_customer_id)
      end
    end

    redirect_to admin_membership_path(@membership), notice: "Attached to #{user.email}."
  rescue ActiveRecord::RecordNotUnique
    # Same shape as create's rescue: index_memberships_one_grant_per_user_per_source
    # blocks attaching an unattached comped/legacy row to a user who already
    # holds a grant of that source. Nothing in app/ currently produces an
    # unattached non-stripe row, so this is a low-reachability belt-and-braces
    # match for create's, not a path exercised in normal operation.
    redirect_to admin_membership_path(@membership), alert: "That user already has a grant of this type."
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

  # A Stripe membership is owned by the reconciler: the nightly sweep rewrites
  # status, interval, period end and cancellation from Stripe, so an edit here
  # would appear to work and then vanish. Refusing is the honest answer.
  def editable?
    !@membership.source_stripe?
  end

  def stripe_owned_message
    "This membership is owned by Stripe. Change it in the Stripe dashboard — the nightly reconcile will pick it up."
  end

  def comp_params
    # source and stripe_subscription_id are absent on purpose. source is
    # hardcoded to :comped in create; a subscription id on a non-Stripe row is
    # rejected by Membership's absence validation regardless.
    #
    # .expect, not .require(...).permit(...): a scalar body (membership=x)
    # makes params[:membership] a String, and .permit on a String is a
    # NoMethodError -> 500. .expect raises ParameterMissing for the wrong
    # shape too, which Rails renders as 400 -- the correct response to a
    # malformed request. Permitted-key behaviour is unchanged; verified in
    # the forgery tests below.
    params.expect(membership: [:user_id, :note, :current_period_end])
  end

  # No user_id: which person a membership belongs to is changed through
  # `attach`, which has its own guards, never by editing a form field.
  def edit_params
    params.expect(membership: [:note, :current_period_end])
  end
end
