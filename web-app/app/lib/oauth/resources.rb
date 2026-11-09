# frozen_string_literal: true

module Oauth
  # The resources an OAuth token can be issued for (spec D3, D17): one row per
  # MCP endpoint, keyed by a short string stored on OauthConnection#resource.
  # The path is what binds a token to its endpoint. The authenticator maps the
  # request path to a resource and refuses a token whose connection is for a
  # different one, so a token for /api/mcp is worthless on /api/mcp/admin and on
  # every /api/v1/* route (those map to no resource at all).
  #
  # Two entries: `mcp` (the member endpoint) and `mcp_admin` (the admin one,
  # which offers the admin scopes). A token for one is a 401 on the other.
  #
  # Scopes are built from the domain, as Api::McpController#required_scope
  # builds the scope it checks, so nothing here names a site.
  module Resources
    Resource = Struct.new(:key, :path, :admin, keyword_init: true) do
      # An admin resource offers every admin scope of the domain, in registry
      # order; a member resource offers the domain's read scope.
      def scopes(domain)
        return ["#{domain}:read"] unless admin

        ::Api::Scopes.all.select { |scope| ::Api::Scopes.admin?(scope) && scope.start_with?("#{domain}:") }
      end

      def url(base_url) = base_url + path

      # RFC 9728 section 3.1: the well-known prefix goes between the host and
      # the resource's path.
      def metadata_path = "/.well-known/oauth-protected-resource" + path
    end

    ALL = {
      "mcp" => Resource.new(key: "mcp", path: "/api/mcp", admin: false),
      "mcp_admin" => Resource.new(key: "mcp_admin", path: "/api/mcp/admin", admin: true)
    }.freeze

    def self.keys = ALL.keys

    def self.fetch(key) = ALL.fetch(key.to_s)

    # An exact match on the request path: no trailing-slash or case folding, so
    # `/api/mcp/` and `/api/mcp/admin` are not the mcp resource.
    def self.for_path(path) = ALL.values.find { |resource| resource.path == path }

    def self.for_url(url, base_url)
      return nil if url.blank?

      ALL.values.find { |resource| resource.url(base_url) == url }
    end

    # The resource a client meant when it named none: the admin one if it asked
    # for any admin scope and one is registered, else mcp. Unknown scope names
    # (offline_access) are ignored.
    def self.infer(scopes)
      asked_admin = Array(scopes).any? { |scope| ::Api::Scopes.known?(scope) && ::Api::Scopes.admin?(scope) }
      (asked_admin && ALL.values.find(&:admin)) || fetch("mcp")
    end

    # What an approval may grant `user` (P-f): what was asked for, or all of the
    # resource's scopes when nothing was, limited to what the member may hold and
    # to what the resource offers. `offline_access` names no scope, so a request
    # that asks for nothing else asked for nothing, and gets the same as no scope
    # at all. An empty result means nothing can be granted.
    def self.grantable_scopes(user, resource, domain, requested: nil)
      offered = resource.scopes(domain)
      asked = Array(requested) - ["offline_access"]
      asked = offered if asked.empty?
      offered & asked & ::Api::Scopes.mintable_by(user)
    end

    # What a connection's token may do right now: the connection's scopes cut
    # down to what its user may hold today, or nothing when that leaves none of
    # the scopes its resource offers. A demoted admin's admin connection is
    # therefore empty even though `effective` still implies a member's read scope,
    # so the client gets a 401 and signs in again rather than a 403 (D12).
    def self.usable_scopes(connection, domain)
      effective = ::Api::Scopes.effective(connection.scopes, connection.user)
      resource = ALL[connection.resource.to_s]
      return [] unless resource

      offered = resource.scopes(domain)
      effective.intersect?(offered) ? effective : []
    end

    def self.all_scopes(domain) = ALL.values.flat_map { |resource| resource.scopes(domain) }.uniq
  end
end
