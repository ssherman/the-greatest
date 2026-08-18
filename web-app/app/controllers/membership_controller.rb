# frozen_string_literal: true

# The join / support page and the three write actions behind it.
#
# Global route, per-domain layout, never edge-cached: the page renders
# differently for members and non-members, and it is low-traffic enough that
# no-store costs nothing.
#
# Nothing here accepts a price, an amount or a user id from the client. The only
# thing a request may name is a plan KEY, which is looked up against
# billing_plans; a client that could name a price could name a one-cent one.
class MembershipController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :prevent_caching
  before_action :require_signed_in!, only: [:checkout, :portal]

  # Declared AFTER require_signed_in! -- filters run in declaration order and
  # rate_limit installs its own before_action, so an anonymous request to
  # :checkout is already turned away before by: runs. Donations are deliberately
  # open to anonymous visitors, so they are bucketed by IP.
  #
  # The webhook endpoint is NOT rate limited anywhere: throttling it would mean
  # dropping legitimate Stripe deliveries.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user&.id || request.remote_ip },
    with: -> { redirect_to membership_path, alert: "Too many attempts just now. Please try again in a minute." },
    store: Rails.application.config.x.rate_limit_store,
    only: [:checkout, :donate, :portal, :thanks]

  # GET /membership
  def show
    @membership = current_user&.granting_membership
    @plans = BillingPlan.membership.active
    @donation_plan = BillingPlan.donation_price
  end

  # POST /membership/checkout
  def checkout
    # An existing member buying a second subscription would be billed twice and
    # would need both cancelling by hand. Send them where they can manage the
    # one they have.
    return portal if current_user.member?

    plan = BillingPlan.membership.active.find_by(key: params[:plan])
    return redirect_to(membership_path, alert: "That membership option is not available.") if plan.nil?

    customer = Services::Billing::EnsureCustomer.call(user: current_user)
    return redirect_to(membership_path, alert: checkout_error) unless customer.success?

    result = Services::Billing::CreateCheckoutSession.call(
      plan: plan,
      user: current_user,
      customer_id: customer.data,
      domain: Current.domain,
      success_url: membership_thanks_url(host: request.host),
      cancel_url: membership_url(host: request.host)
    )
    return redirect_to(membership_path, alert: checkout_error) unless result.success?

    # allow_other_host is required: Rails blocks cross-host redirects by default
    # and raises rather than warning.
    redirect_to result.data, allow_other_host: true, status: :see_other
  end

  # POST /membership/donate -- deliberately open to anonymous visitors. Stripe
  # collects the email, and no Customer is created for a one-off donor.
  def donate
    plan = BillingPlan.donation_price
    return redirect_to(membership_path, alert: "Donations are unavailable right now.") if plan.nil?

    customer_id = if current_user
      result = Services::Billing::EnsureCustomer.call(user: current_user)
      result.success? ? result.data : nil
    end

    result = Services::Billing::CreateCheckoutSession.call(
      plan: plan,
      user: current_user,
      customer_id: customer_id,
      domain: Current.domain,
      success_url: membership_thanks_url(host: request.host),
      cancel_url: membership_url(host: request.host)
    )
    return redirect_to(membership_path, alert: checkout_error) unless result.success?

    redirect_to result.data, allow_other_host: true, status: :see_other
  end

  # POST /membership/portal
  def portal
    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      return redirect_to membership_path,
        alert: "There is no billing account attached to your membership."
    end

    result = Services::Billing::CreatePortalSession.call(
      customer_id: customer_id, return_url: membership_url(host: request.host)
    )
    return redirect_to(membership_path, alert: checkout_error) unless result.success?

    redirect_to result.data, allow_other_host: true, status: :see_other
  end

  # GET /membership/thanks
  #
  # Grants NOTHING. It re-reads Stripe for the signed-in visitor's own customer
  # id so the page is truthful before the webhook lands -- a subscription that
  # does not exist in Stripe produces no membership here, and a visitor who
  # simply types this URL gets a thank-you page and no entitlement.
  def thanks
    @membership = current_user&.granting_membership
    return if current_user&.stripe_customer_id.blank?

    Services::Billing::ReconcileCustomer.call(stripe_customer_id: current_user.stripe_customer_id)
    @membership = current_user.granting_membership
  end

  private

  # One message for every failure mode. The specific Stripe error is logged by
  # the service; showing it to the visitor would leak request parameters that
  # Stripe echoes back in some error strings.
  def checkout_error
    "Something went wrong starting that payment. Please try again, and let us know if it keeps happening."
  end
end
