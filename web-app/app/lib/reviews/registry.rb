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
  end
end
