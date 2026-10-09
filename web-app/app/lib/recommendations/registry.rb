# frozen_string_literal: true

module Recommendations
  # Which adapter, page loader and membership feature serve which domain.
  # Mirrors SavedSearch::DOMAIN_SUBCLASSES. A domain absent here has no
  # recommendations: the controller 404s on its host.
  module Registry
    DOMAIN_ADAPTERS = {"books" => "Recommendations::Books::Adapter"}.freeze
    DOMAIN_PAGES = {"books" => "Recommendations::Books::Pages"}.freeze
    MEMBERSHIP_FEATURES = {"books" => :book_recommendations}.freeze

    def self.adapter_class_for(domain)
      DOMAIN_ADAPTERS[domain.to_s]&.constantize
    end

    def self.pages_class_for(domain)
      DOMAIN_PAGES[domain.to_s]&.constantize
    end

    def self.membership_feature_for(domain)
      MEMBERSHIP_FEATURES[domain.to_s]
    end
  end
end
