class ContactMessagesController < ApplicationController
  include Cacheable
  include VisitorIp

  # The footer form is served from the Cloudflare cache, so its authenticity
  # token belongs to whoever populated that cache. contact--form fetches a real
  # one from /contact_state when the modal opens -- but if that fetch never
  # happened (JS off, blocked, slow), null_session accepts the write as
  # ANONYMOUS rather than showing a 422 the submitter cannot act on.
  #
  # Sound, not a compromise: CSRF exists to stop a forged request riding a
  # victim's ambient authority, and null_session removes exactly that authority.
  # What lands is a message the attacker could have posted directly, into a
  # queue a human reads before anything happens.
  protect_from_forgery with: :null_session, only: [:create]

  before_action :prevent_caching

  # Two buckets. An anonymous submitter shares an IP bucket and cannot be
  # identified, so the cap is tight; a signed-in one is attributable and can be
  # banned, so theirs is looser. Both are guesses -- legacy stored no contact
  # messages, so there is no history to set them from.
  #
  # by: goes through visitor_ip, NEVER request.remote_ip, which in production is
  # the Cloudflare edge IP and would put every visitor in one bucket.
  #
  # with: is not optional -- Rails' default raises TooManyRequests and renders an
  # HTML error body, which would blank the modal.
  ANONYMOUS_RATE = 5
  SIGNED_IN_RATE = 20
  RATE_WINDOW = 1.hour

  rate_limit to: SIGNED_IN_RATE, within: RATE_WINDOW,
    by: -> { current_user.id },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "contact-messages-create-signed-in",
    only: [:create],
    if: -> { current_user.present? }

  rate_limit to: ANONYMOUS_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "contact-messages-create-anonymous",
    only: [:create],
    unless: -> { current_user.present? }

  def create
    # Same response as a real success. A bot told its submission was discarded
    # learns to try again differently.
    return render_sent if honeypot_filled?

    result = Services::ContactMessages::Submission.call(
      email: contact_params[:email],
      message: contact_params[:message],
      user: current_user,
      domain: Current.domain,
      submitter_ip: visitor_ip
    )

    if result.success?
      render_sent
    else
      @error = result.errors.to_sentence
      render :create, formats: [:turbo_stream], status: :unprocessable_entity
    end
  end

  private

  def contact_params
    params.fetch(:contact_message, {}).permit(:email, :message)
  end

  def honeypot_filled? = params[:website].present?

  def render_sent
    @sent = true
    render :create, formats: [:turbo_stream]
  end

  # Shared by both rate-limit buckets so a throttled submitter sees the same
  # thing either way, and so the two declarations cannot drift apart.
  def render_rate_limited
    @error = "Thanks — you've sent us several messages just now. Please try again shortly."
    render :create, formats: [:turbo_stream], status: :too_many_requests
  end
end
