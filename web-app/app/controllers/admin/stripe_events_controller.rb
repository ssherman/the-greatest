# The operator's window into the raw webhook inbox.
#
# Admin-only, and not only because billing is money: a Stripe event payload
# carries customer email, name, address and card last four. StripeEvent
# deliberately refuses to write a payload to the log for that reason, and this
# controller is the one place it is rendered at all.
class Admin::StripeEventsController < Admin::BaseController
  before_action :require_admin_role!
  before_action :set_event, only: [:show, :reprocess]

  def index
    scope = StripeEvent.all
    scope = scope.where(status: params[:status]) if StripeEvent.statuses.key?(params[:status])

    @search_query = params[:q].to_s.presence
    if @search_query
      pattern = "%#{::StripeEvent.sanitize_sql_like(@search_query)}%"
      scope = scope.where(
        "stripe_event_id ILIKE :p OR event_type ILIKE :p OR stripe_customer_id ILIKE :p",
        p: pattern
      )
    end

    @failed_count = StripeEvent.failed.count
    @pagy, @events = pagy(scope.order(stripe_created_at: :desc, id: :desc), limit: 50)
  end

  def show
  end

  # `reprocess`, not `retry`: `retry` is a Ruby keyword and `def retry` will not
  # parse. POST only -- re-running an event enqueues work and calls the Stripe
  # API, which must never happen because something prefetched a link.
  def reprocess
    unless @event.received? || @event.failed?
      redirect_to admin_stripe_event_path(@event),
        alert: "Only a received or failed event can be re-run. This one is #{@event.status}."
      return
    end

    ::Billing::ProcessStripeEventJob.perform_async(@event.id)
    redirect_to admin_stripe_event_path(@event), notice: "Re-enqueued for processing."
  end

  private

  def set_event
    @event = StripeEvent.find(params[:id])
  end
end
