# frozen_string_literal: true

module Api
  module V1
    # Every authenticated API endpoint inherits from here. ActionController::API:
    # no session, no cookies, no CSRF, no allow_browser (which would 406 curl).
    #
    # before_action order is load-bearing and follows include order:
    #   1. set_current_domain   (CurrentDomain)      -- Current.domain from the host
    #   2. prevent_caching      (Cacheable)          -- private, no-store on EVERY response
    #   3. authenticate!        (Api::Authentication)
    #   4. enforce_rate_limit!  (Api::RateLimited)
    #   5. require_scope!
    class BaseController < ActionController::API
      include CurrentDomain
      include Cacheable
      include VisitorIp
      include ::Api::ErrorRendering

      before_action :prevent_caching

      include ::Api::Authentication
      include ::Api::RateLimited

      class_attribute :required_scope, instance_writer: false

      before_action :require_scope!

      def self.require_scope(scope) = self.required_scope = scope

      private

      def require_scope!
        scope = required_scope
        raise "#{self.class.name} declares no required_scope" if scope.nil?
        return if current_principal.scope?(scope)

        render_problem(
          ::Api::Problem.new(:insufficient_scope, detail: "This endpoint requires the #{scope} scope."),
          www_authenticate: %(Bearer error="insufficient_scope", scope="#{scope}")
        )
      end

      # Paginates a rank-ordered relation (or nil, when there is no ranking to
      # read from) and renders the collection envelope. The block turns one
      # RankedItem row into its hash. Page params are validated even when the
      # relation is nil so a bad page is always a 400.
      def render_ranked_page(relation, path:)
        page = ::Api::Page.from_params(params, total_count: relation&.count || 0)
        rows = relation ? relation.offset(page.offset).limit(page.per_page) : []

        render json: {
          data: rows.map { |row| yield(row) },
          meta: page.meta,
          links: page.links("#{::Api::Host.base_url}#{path}")
        }
      end
    end
  end
end
