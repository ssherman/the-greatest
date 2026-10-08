# frozen_string_literal: true

module Recommendations
  # Which adapter serves which domain. Mirrors SavedSearch::DOMAIN_SUBCLASSES.
  # A domain absent here has no recommendations.
  module Registry
    DOMAIN_ADAPTERS = {"books" => "Recommendations::Books::Adapter"}.freeze

    def self.adapter_class_for(domain)
      DOMAIN_ADAPTERS[domain.to_s]&.constantize
    end
  end
end
