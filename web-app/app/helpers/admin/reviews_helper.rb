module Admin
  module ReviewsHelper
    # An absolute URL, not a path, and deliberately so. /admin/users/:id is in the
    # global admin namespace with no DomainConstraint, so it answers on all four
    # hostnames; /admin/reviews is inside the books DomainConstraint and routes on
    # the books host alone. A path-only link is dead for any admin browsing on
    # music or games.
    #
    # Scheme and port come from the current request rather than being hardcoded:
    # development serves these hostnames over http on port 3000, production over
    # https on 443. request.port_string is "" on a default port.
    #
    # Returns nil for a reviewable type no domain claims, so the caller can render
    # the row unlinked. A user page must not 500 over one stray review.
    #
    # Named cross_domain_review_url, NOT admin_review_url: this module is mixed
    # into every admin view (it lives in app/helpers, not scoped to one
    # controller), and the music admin namespace is declared with no `as:`
    # prefix (config/routes.rb) -- unlike books and games. The day
    # `resources :reviews` is added there, Rails generates a route helper
    # ALSO named admin_review_url, and a helper method wins over a route helper
    # on ancestor precedence, so the route helper would be silently shadowed.
    # This is the identical trap Admin::ReviewsBaseController documents twice
    # already, for reviews_path and review_path.
    def cross_domain_review_url(review)
      path = ::Reviews::Registry.admin_path_for(review)
      return nil if path.nil?

      domain = ::Reviews::Registry.domain_for_type(review.reviewable_type)
      return nil if domain.nil?

      host = Rails.application.config.domains[domain.to_sym]
      return nil if host.blank?

      "#{request.protocol}#{host}#{request.port_string}#{path}"
    end
  end
end
