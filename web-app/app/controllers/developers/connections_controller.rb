# frozen_string_literal: true

module Developers
  # Revokes one connected app (an OAuth connection) from /developers/tokens.
  # No membership check (spec D14): a lapsed member must be able to cut off an
  # app they approved while they were a member. Answers in a Turbo Stream and
  # never caches, like TokensController.
  class ConnectionsController < ApplicationController
    include Cacheable

    before_action :prevent_caching
    before_action :require_sign_in!

    def destroy
      # Scoped through current_user and to live rows: another account's id, or
      # an already-revoked one, is a 404 and never rewrites revoked_at.
      connection = current_user.oauth_connections.live.find(params[:id])
      ::Services::Oauth::Connections.revoke!(connection)
      @connections = current_user.oauth_connections.listed
      render :destroy, formats: [:turbo_stream]
    end

    private

    def require_sign_in!
      return if current_user

      redirect_to membership_path, alert: "Sign in to your membership to open that page."
    end
  end
end
