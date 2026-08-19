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
  # :checkout is already turned away before by: runs. Its own named bucket, keyed
  # by user id, means a compromised or careless account can only hurt itself.
  #
  # The webhook endpoint is NOT rate limited anywhere: throttling it would mean
  # dropping legitimate Stripe deliveries.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user.id },
    with: -> { redirect_to membership_path, alert: "Too many attempts just now. Please try again in a minute." },
    store: Rails.application.config.x.rate_limit_store,
    name: "membership-account",
    only: [:checkout, :portal]

  # :donate is reachable by anyone and creates a real Stripe Checkout Session on
  # every hit -- the most expensive anonymous action here. It gets its own named
  # bucket (rather than sharing the default, action-less scope with :thanks) so
  # a burst of :thanks traffic can never eat into the budget a real donor needs.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user&.id || visitor_ip },
    with: -> { redirect_to membership_path, alert: "Too many attempts just now. Please try again in a minute." },
    store: Rails.application.config.x.rate_limit_store,
    name: "membership-donate",
    only: [:donate]

  # :thanks is where Stripe redirects every successful payer, and it is the one
  # action here an anonymous visitor can hit that does NO Stripe work at all --
  # see #thanks. A much larger budget than :donate reflects that asymmetry, and
  # its own name keeps it from competing with :donate for the same reason.
  rate_limit to: 30, within: 1.minute,
    by: -> { current_user&.id || visitor_ip },
    with: -> { redirect_to membership_path, alert: "Too many attempts just now. Please try again in a minute." },
    store: Rails.application.config.x.rate_limit_store,
    name: "membership-thanks",
    only: [:thanks]

  # GET /membership
  def show
    @membership = current_user&.granting_membership
    @plans = BillingPlan.membership.active
    @donation_plan = BillingPlan.donation_price
  end

  # POST /membership/checkout
  def checkout
    if current_user.member?
      # A comped or legacy member has no Stripe customer at all (see
      # editor_user_comped), so routing them into #portal produced "there is no
      # billing account attached to your membership" -- true, but it reads as an
      # error for someone who did nothing wrong and cannot buy a subscription
      # here anyway. Tell them what actually happened instead.
      if current_user.stripe_customer_id.blank?
        return redirect_to membership_path, notice: "You're already a member -- thank you for your support!"
      end

      # An existing Stripe member buying a second subscription would be billed
      # twice and would need both cancelling by hand. Send them where they can
      # manage the one they have.
      return portal
    end

    plan = BillingPlan.membership.active.find_by(key: params[:plan])
    return redirect_to(membership_path, alert: "That membership option is not available.") if plan.nil?

    customer = Services::Billing::EnsureCustomer.call(user: current_user)
    return redirect_to(membership_path, alert: checkout_error) unless customer.success?

    result = Services::Billing::CreateCheckoutSession.call(
      plan: plan,
      user: current_user,
      customer_id: customer.data,
      domain: Current.domain,
      success_url: membership_thanks_url(host: canonical_host, port: nil),
      cancel_url: membership_url(host: canonical_host, port: nil)
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
      success_url: membership_thanks_url(host: canonical_host, port: nil),
      cancel_url: membership_url(host: canonical_host, port: nil)
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
      customer_id: customer_id, return_url: membership_url(host: canonical_host, port: nil)
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

  # The one host this controller will ever hand to Stripe.
  #
  # NOT request.host: config.hosts is unset in production (see
  # config/environments/production.rb), and nginx forwards the raw client Host
  # header verbatim (proxy_set_header Host $http_host), so request.host is
  # attacker-controlled. A forged Host would otherwise let a visitor mint a real,
  # Stripe-branded Checkout Session whose success_url points anywhere they like,
  # then hand that checkout.stripe.com link to a victim.
  #
  # Current.domain is already resolved once per request by
  # ApplicationController#set_current_domain, which falls back to :books for a
  # Host it does not recognise rather than trusting it -- so reading the
  # canonical hostname back out of config.domains, instead of out of the
  # request, turns a forged Host into a legitimate site host automatically.
  #
  # config.domains values can be a comma-separated list (see DomainConstraint);
  # any one of them is a legitimate host for this domain, so the first is fine.
  #
  # Every call site also passes port: nil alongside this. The hostname alone
  # being canonical is not enough: url_for still inherits port and protocol
  # from url_options, and request.optional_port derives from the same raw Host
  # header this method exists to stop trusting, so a forged "Host: <host>:8443"
  # could otherwise append a port to an already-canonical URL. port: nil closes
  # that off outright rather than relying on it being unreachable today.
  def canonical_host
    Rails.application.config.domains[Current.domain].to_s.split(",").first
  end

  # Prefers the IP Cloudflare recorded for the visitor over the shared edge IP
  # every other visitor at that PoP appears to have. This is correct ONLY for
  # traffic that actually came through Cloudflare: nginx has no real_ip module
  # configured with Cloudflare's ranges (a deployment change, not a code one --
  # see the ops runbook), so nothing here verifies the request came through
  # Cloudflare at all. A request straight to the origin can set this header to
  # anything and evade the rate limit entirely -- it does not merely fall back
  # to request.remote_ip, which alone was at least accurate for that traffic.
  # request.remote_ip is only the fallback when the header is absent, and this
  # test suite never sends it.
  def visitor_ip
    request.headers["CF-Connecting-IP"].presence || request.remote_ip
  end
end
