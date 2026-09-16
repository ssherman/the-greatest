# frozen_string_literal: true

module Developers
  # /developers/tokens -- where a member mints and revokes API tokens.
  #
  # Members only (MembershipGate :api) and never cached: it is per-user by
  # definition. Global route with a per-domain layout, the MembersController
  # shape. The write actions answer with a Turbo Stream in BOTH outcomes:
  # Turbo Drive rejects a 200 HTML page as a form response, a redirect would
  # put the secret in a URL or the flash, and the public layouts render no
  # flash, so every message lives in the page. The secret exists in exactly one
  # response body (create's) and is never re-rendered.
  class TokensController < ApplicationController
    include Cacheable
    include DomainLayout
    include MembershipGated

    layout :resolve_layout

    before_action :prevent_caching
    before_action -> { require_membership!(:api) }

    # Days a token may live, as the form offers them; blank is "never". Any
    # other value is a tampered request and is refused rather than silently
    # made permanent, which would be the less safe reading.
    EXPIRY_DAYS = [30, 90, 365].freeze

    def index
      @tokens = tokens
    end

    def create
      head :not_implemented
    end

    def destroy
      head :not_implemented
    end

    private

    def tokens = current_user.api_tokens.order(:created_at, :id)
  end
end
