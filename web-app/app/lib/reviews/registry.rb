# frozen_string_literal: true

module Reviews
  # Single source of truth for which classes are reviewable, and which domain
  # each belongs to.
  #
  # This is security-relevant, not just organisational: reviewable_type arrives
  # from the browser, and without an allowlist a visitor could attach a review to
  # an arbitrary class. That allowlist previously existed as a private constant in
  # two separate controllers, which meant adding a domain silently half-worked.
  class Registry
    DOMAIN_TYPES = {
      "books" => ["Books::Book"].freeze
    }.freeze

    def self.types_for(domain)
      DOMAIN_TYPES[domain.to_s] || []
    end

    def self.classes_for(domain)
      types_for(domain).map(&:constantize)
    end

    def self.allowed?(type)
      DOMAIN_TYPES.each_value.any? { |types| types.include?(type.to_s) }
    end

    # Where a review of each reviewable type is administered. Lives here rather
    # than in Admin::DomainRouting::ENTITIES because those lambdas are keyed by,
    # and receive, the ENTITY -- a Books::Book -- while this one is keyed by the
    # entity's type but receives the REVIEW. This class is already the single
    # source of truth for type-to-domain, so the routing belongs beside it.
    ADMIN_PATHS = {
      "Books::Book" => ->(review) { Rails.application.routes.url_helpers.admin_books_review_path(review) }
    }.freeze

    def self.domain_for_type(type)
      DOMAIN_TYPES.find { |_domain, types| types.include?(type.to_s) }&.first
    end

    def self.admin_path_for(review)
      ADMIN_PATHS[review.reviewable_type]&.call(review)
    end
  end
end
