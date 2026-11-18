# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # The list of queue types. Tasks add the real type class names to TYPE_NAMES.
    class Registry
      class UnknownKind < StandardError; end

      TYPE_NAMES = %w[
        Services::Books::QueueTypes::Origin Services::Books::QueueTypes::Categories Services::Books::QueueTypes::BookFacts
        Services::Books::QueueTypes::AuthorFacts
      ].freeze

      # Constantized on every call in development so code reloading is seen;
      # memoized elsewhere, like Mcp::Catalog.
      def self.types
        return TYPE_NAMES.map(&:constantize) if Rails.env.development?

        @types ||= TYPE_NAMES.map(&:constantize).freeze
      end

      def self.fetch(kind)
        types.find { |type| type.kind == kind } || raise(UnknownKind, "unknown enrichment kind: #{kind.inspect}")
      end

      def self.for_domain(domain)
        types.select { |type| type.domain == domain.to_s }
      end

      def self.find(domain:, slug:)
        for_domain(domain).find { |type| type.slug == slug.to_s }
      end
    end
  end
end
