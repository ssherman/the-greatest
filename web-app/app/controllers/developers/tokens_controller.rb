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
      unless valid_expiry?(token_params[:expires_in])
        return render_form_again(errors: ["Choose an expiry from the list"])
      end

      result = Services::Api::Tokens.generate(
        user: current_user,
        name: token_params[:name].to_s.strip,
        scopes: Array(token_params[:scopes]).reject(&:blank?),
        expires_at: expires_at_from(token_params[:expires_in])
      )

      if result.success?
        @token = result.data[:token]
        @secret = result.data[:secret]
        @tokens = tokens
        render :create, formats: [:turbo_stream]
      else
        render_form_again(errors: result.errors)
      end
    end

    def destroy
      # Scoped through current_user: another account's id is a 404, never a
      # revoke. find (not find_by) so the missing case is Rails' 404.
      current_user.api_tokens.find(params[:id]).destroy!
      @tokens = tokens
      render :destroy, formats: [:turbo_stream]
    end

    private

    def tokens = current_user.api_tokens.order(:created_at, :id)

    # params[:api_token] is untrusted SHAPE as well as content: a hand-built
    # request can send it as a scalar, on which permit raises NoMethodError.
    # Fall back to empty permitted parameters, which fail validation the
    # ordinary way (ContactMessagesController#contact_params does the same).
    def token_params
      candidate = params[:api_token]
      return ActionController::Parameters.new.permit(:name, :expires_in, scopes: []) unless candidate.is_a?(ActionController::Parameters)

      candidate.permit(:name, :expires_in, scopes: [])
    end

    def valid_expiry?(value) = value.blank? || EXPIRY_DAYS.include?(Integer(value, exception: false))

    def expires_at_from(value) = value.blank? ? nil : Integer(value).days.from_now

    # Every failure lands here so what the member typed survives the error.
    # Safe to echo: this response is uncached (prevent_caching) and answers
    # exactly one request.
    def render_form_again(errors:)
      @errors = errors
      @tokens = tokens
      @name_value = token_params[:name]
      @scopes_value = Array(token_params[:scopes]).reject(&:blank?)
      @expires_in_value = token_params[:expires_in]
      render :create, formats: [:turbo_stream], status: :unprocessable_entity
    end
  end
end
