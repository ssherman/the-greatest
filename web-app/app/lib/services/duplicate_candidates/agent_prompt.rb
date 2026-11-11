# frozen_string_literal: true

module Services
  module DuplicateCandidates
    # The starting prompt the duplicates admin page's Copy prompt button copies,
    # rendered from config/mcp/<domain>/prompts/duplicates.md.erb. Returns the
    # String, or nil for a domain with no prompt file (that domain gets no button).
    #
    # Books is the only domain with a prompt, so its two item types are named
    # here; a second domain's template brings its own counts with it.
    class AgentPrompt
      BOOK_TYPES = {pending_books: "Books::Book", pending_authors: "Books::Author"}.freeze

      def self.call(domain:)
        new(domain: domain).call
      end

      def initialize(domain:)
        @domain = domain.to_s
      end

      def call
        return unless file.exist?

        ERB.new(file.read).result_with_hash(
          {mcp_url: "#{::Api::Host.base_url}/api/mcp/admin"}.merge(pending_counts)
        )
      end

      private

      def file
        Rails.root.join("config", "mcp", @domain, "prompts", "duplicates.md.erb")
      end

      def pending_counts
        models = ::DataImporters::FinderRegistry.for_domain(@domain).map(&:model)
        pending = ::DuplicateCandidate.pending.where(item_type: models).group(:item_type).count
        BOOK_TYPES.transform_values { |type| pending[type].to_i }
      end
    end
  end
end
