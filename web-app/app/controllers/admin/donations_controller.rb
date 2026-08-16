# Read-only by design. Donations are payment history: a webhook records them,
# or the legacy import does. Nothing about a completed payment should be
# editable from a web form.
class Admin::DonationsController < Admin::BaseController
  before_action :require_admin_role!

  def index
    scope = Donation.includes(:user)
    scope = scope.where(status: params[:status]) if Donation.statuses.key?(params[:status])

    @search_query = params[:q].to_s.presence
    if @search_query
      pattern = "%#{::Donation.sanitize_sql_like(@search_query)}%"
      scope = scope.where(
        "donations.stripe_payment_intent_id ILIKE :p OR donations.email ILIKE :p " \
        "OR donations.user_id IN (SELECT id FROM users WHERE email ILIKE :p)",
        p: pattern
      )
    end

    # Over the whole table, not the filtered page: "how much has been given"
    # is the question this answers, and a per-page subtotal answers nothing.
    @succeeded_total_cents = Donation.successful.sum(:amount_cents)
    @pagy, @donations = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end
end
