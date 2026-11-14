# frozen_string_literal: true

module Services
  # The starting prompts the admin pages' Copy prompt buttons copy, rendered from
  # config/mcp/<domain>/prompts/<queue>.md.erb. Returns the String, or nil for a
  # domain with no prompt file for that queue (that page gets no button).
  #
  # Books is the only domain with prompts, so its item types are named here; a
  # second domain's template brings its own counts with it.
  class AgentPrompts
    QUEUES = %i[duplicates match_decisions repair_verdicts].freeze

    DUPLICATE_TYPES = {pending_books: "Books::Book", pending_authors: "Books::Author"}.freeze
    DECISION_FINDERS = {
      pending_wikidata: "Services::Books::Authors::ResolveWikidata",
      pending_viaf: "Services::Books::Authors::ResolveViaf",
      pending_authors: "DataImporters::Books::Author::Finder"
    }.freeze

    def self.call(domain:, queue:)
      new(domain: domain, queue: queue).call
    end

    def initialize(domain:, queue:)
      raise ArgumentError, "unknown queue #{queue.inspect}" unless QUEUES.include?(queue.to_sym)

      @domain = domain.to_s
      @queue = queue.to_sym
    end

    def call
      return unless file.exist?

      ERB.new(file.read).result_with_hash(
        {mcp_url: "#{::Api::Host.base_url}/api/mcp/admin"}.merge(counts)
      )
    end

    private

    def file
      Rails.root.join("config", "mcp", @domain, "prompts", "#{@queue}.md.erb")
    end

    def counts
      case @queue
      when :duplicates then duplicate_counts
      when :repair_verdicts then repair_verdict_counts
      else decision_counts
      end
    end

    # The proposed re-import matches by confidence, as the page's default view
    # shows them with kind=reimport_match.
    def repair_verdict_counts
      pending = ::Books::RepairVerdict.current.reimport_match.proposed.group(:confidence).count
      %w[high medium low].to_h { |level| [:"pending_#{level}", pending[level].to_i] }
    end

    def duplicate_counts
      models = ::DataImporters::FinderRegistry.for_domain(@domain).map(&:model)
      pending = ::DuplicateCandidate.pending.where(item_type: models).group(:item_type).count
      DUPLICATE_TYPES.transform_values { |type| pending[type].to_i }
    end

    # Matches the page's default view: needing review, not reviewed, verify runs hidden.
    def decision_counts
      finders = ::DataImporters::FinderRegistry.for_domain(@domain).map(&:finder)
      pending = ::MatchDecision.needing_review.where(verify: false, finder: finders).group(:finder).count
      DECISION_FINDERS.transform_values { |finder| pending[finder].to_i }
    end
  end
end
