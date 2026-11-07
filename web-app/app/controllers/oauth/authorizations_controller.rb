# frozen_string_literal: true

module Oauth
  # The page a member lands on from Claude or Codex: sign in, see what is asked,
  # Approve or Deny (spec D4, D5, D16). Doorkeeper's own controller supplies the
  # protocol (PKCE and scope validation, the code, the error redirects); this one
  # decides what the page does with a request, in this order:
  #
  #   1. an unknown client or unregistered redirect URI: an error page, never a
  #      redirect (RFC 6749 3.1.2.4);
  #   2. signed out: a sign-in prompt. The layout's login widget reloads the same
  #      URL, so the request comes back with its query intact;
  #   3. a request Doorkeeper refuses (bad scope, `plain` PKCE): an error redirect;
  #   4. a `resource` this server does not know: `invalid_target` on the redirect;
  #   5. nothing grantable (not a member): the ineligible page, whose Return form
  #      is the deny action;
  #   6. the approval screen.
  #
  # POST (Approve) runs every one of those checks again and never trusts the
  # hidden fields: the scopes granted are recomputed from what the member may
  # hold, and the connection, the code's scope and `approved_at` are all stamped
  # here. A client-sent `connection_id` is dropped.
  #
  # The client's name is whatever it registered with, so nothing on these pages
  # treats it as an identity: the redirect host is the primary signal and the
  # name is escaped text.
  class AuthorizationsController < Doorkeeper::AuthorizationsController
    include DomainLayout

    layout :resolve_layout

    before_action :prevent_caching

    helper_method :request_fields

    def new
      return if review!(strict: false)

      render :new
    end

    def create
      return if review!(strict: true)

      application = pre_auth.client.application
      result = ::Services::Oauth::Connections.approve(
        user: current_user, application: application, resource_key: @resource.key, scopes: @scopes
      )
      return redirect_or_render(failure_response) unless result.success?

      # Rebuilt from the request plus what the server decided: the connection it
      # just made and the scopes it will grant. Nothing the client sent can
      # replace either.
      @server_params = {connection_id: result.data.id, scope: @scopes.join(" ")}
      @pre_auth = nil
      redirect_or_render(authorize_response)
    end

    private

    # Renders or redirects and answers true when the request must not go on.
    # `strict` is the POST: a refusal there is an error status, not a page.
    def review!(strict:)
      return true if refuse_invalid_client?

      describe_request

      unless current_user
        render :signed_out, status: strict ? :unauthorized : :ok
        return true
      end

      unless pre_auth.authorizable?
        render_error
        return true
      end

      @resource = requested_resource
      unless @resource
        redirect_or_render(invalid_target_response)
        return true
      end

      @scopes = ::Oauth::Resources.grantable_scopes(
        current_user, @resource, Current.domain, requested: pre_auth.scopes.to_a
      )
      if @scopes.empty?
        render :ineligible, status: strict ? :forbidden : :ok
        return true
      end

      false
    end

    def describe_request
      @client_name = pre_auth.client.name
      @redirect_host = redirect_host(pre_auth.redirect_uri)
    end

    # The host the member is about to be sent to, with the port unless it is
    # the scheme's default: a loopback client listens on a port of its own.
    def redirect_host(redirect_uri)
      uri = URI.parse(redirect_uri.to_s)
      (uri.port == uri.default_port) ? uri.host : "#{uri.host}:#{uri.port}"
    end

    # P-g. Absent: inferred from the scopes. Present: exactly a registered
    # resource's URL. Anything else, an array or a hash included, is unknown.
    def requested_resource
      raw = params[:resource]
      return ::Oauth::Resources.infer(pre_auth.scopes.to_a) if raw.blank?
      return nil unless raw.is_a?(String)

      ::Oauth::Resources.for_url(raw, ::Api::Host.base_url)
    end

    def invalid_target_response
      ::Doorkeeper::OAuth::ErrorResponse.new(
        name: :invalid_target, state: pre_auth.state, redirect_uri: pre_auth.redirect_uri
      )
    end

    def failure_response
      ::Doorkeeper::OAuth::ErrorResponse.new(
        name: :server_error, state: pre_auth.state, redirect_uri: pre_auth.redirect_uri
      )
    end

    # Everything the Approve and Deny forms send back, so the POST is the same
    # request the member was shown.
    def request_fields
      {
        client_id: pre_auth.client.uid,
        redirect_uri: pre_auth.redirect_uri,
        response_type: pre_auth.response_type,
        state: pre_auth.state,
        code_challenge: pre_auth.code_challenge,
        code_challenge_method: pre_auth.code_challenge_method,
        scope: pre_auth.scope,
        resource: @resource&.url(::Api::Host.base_url)
      }.compact
    end

    # Doorkeeper's fields without the custom attributes: `connection_id` is never
    # read from the request, it is merged in by the server on Approve.
    def pre_auth_param_fields
      super - custom_access_token_attributes
    end

    # Doorkeeper's own ScopeChecker refuses a blank scope, which would fail the
    # request before the rule "absent scope means all of the resource's scopes"
    # could apply, so the scope is filled in before Doorkeeper sees the request.
    # What is actually granted is still the grantable subset of it.
    def pre_auth_params
      permitted = super
      permitted[:scope] = default_scope if permitted[:scope].blank?
      permitted.merge(@server_params || {})
    end

    def default_scope
      raw = params[:resource]
      resource = (raw.is_a?(String) && ::Oauth::Resources.for_url(raw, ::Api::Host.base_url)) ||
        ::Oauth::Resources.infer([])
      resource.scopes(Current.domain).join(" ")
    end
  end
end
