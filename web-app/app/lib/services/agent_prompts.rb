# frozen_string_literal: true

module Services
  # The starting prompts the admin pages' Copy prompt buttons copy, rendered from
  # config/mcp/<domain>/prompts/<queue>.md.erb. Returns the String, or nil for a
  # domain with no prompt file for that queue (that page gets no button).
  #
  # Books is the only domain with prompts, so its item types are named here; a
  # second domain's template brings its own counts with it.
  class AgentPrompts
    QUEUES = %i[duplicates match_decisions repair_verdicts author_verdicts row_moves series book_submissions].freeze

    DUPLICATE_TYPES = {pending_books: "Books::Book", pending_authors: "Books::Author"}.freeze
    DECISION_FINDERS = {
      pending_wikidata: "Services::Books::Authors::ResolveWikidata",
      pending_viaf: "Services::Books::Authors::ResolveViaf",
      pending_authors: "DataImporters::Books::Author::Finder"
    }.freeze

    def self.call(domain:, queue:)
      new(domain: domain, queue: queue).call
    end

    # The copy prompt for one enrichment queue type, rendered from
    # config/mcp/<domain>/prompts/enrichment/<slug>.md.erb. The type's own
    # prompt_locals carry what the file shares with the paid task (its rules).
    # Nil when the type has no prompt file.
    def self.for_enrichment(type)
      file = Rails.root.join("config", "mcp", type.domain, "prompts", "enrichment", "#{type.slug}.md.erb")
      return unless file.exist?

      locals = {mcp_url: mcp_url, type: type.slug, label: type.label,
                pending: ::EnrichmentRequest.for_kind(type.kind).pending.count}
      ERB.new(file.read).result_with_hash(locals.merge(type.prompt_locals))
    end

    # The list audit prompt. With a list, it audits that one list and shows its
    # current state (what get_admin_list returns); without, it works the queue.
    def self.for_list_audit(list: nil)
      file = Rails.root.join("config", "mcp", "books", "prompts", "list_audit.md.erb")
      locals = {mcp_url: mcp_url, remaining: list ? nil : ::Services::Lists::Audits::Queue.remaining, list: list,
                list_block: list && list_audit_block(list),
                primary_median_voters: primary_median_voters}
      ERB.new(file.read, trim_mode: "-").result_with_hash(locals)
    end

    # The median the weight calculator uses: the configuration's, or 50 when it has none.
    # Nil only when there is no default primary configuration.
    def self.primary_median_voters
      primary = ::Books::RankingConfiguration.default_primary
      primary && (primary.median_voter_count || 50)
    end

    def self.list_audit_block(list)
      full = ::Api::V1::Admin::Books::ListFullResource.for(list)
      lines = ["id: #{list.id}", "name: #{list.name}", "source: #{value_text(list.source)}",
        "url: #{value_text(list.url)}", "year_published: #{value_text(list.year_published)}"]
      (::Api::V1::Admin::Books::ListFullResource::FIELDS - %w[name source url year_published]).each do |field|
        lines << "#{field}: #{value_text(full[field.to_sym]).gsub("\n", "\n  ")}"
      end
      lines << "penalties attached:"
      lines.concat(full[:penalties].map { |p| "  #{p[:id]} — #{p[:name]} (#{p[:kind]})" })
      lines << "  none" if full[:penalties].empty?
      lines.concat(weight_lines(full[:weight_details]))
      # The block sits inside a four-backtick fence in the prompt; no run of 4+ backticks
      # in a value may close it.
      lines.join("\n").gsub(/`{4,}/, "```")
    end

    def self.weight_lines(details)
      final = details.is_a?(Hash) && details["final_calculation"]
      return ["weight on the main ranking: not calculated yet"] if final.blank?

      lines = ["weight on the main ranking: #{final["final_weight"]} (total penalty #{final["total_penalty_percentage"]&.round(1)}%)"]
      Array(details["penalties"]).each do |p|
        lines << "  #{p["penalty_name"]} (#{p["source"]}): #{p["value"].to_f.round(1)}%"
      end
      lines
    end

    def self.value_text(value) = value.nil? ? "null" : value.to_s

    private_class_method :list_audit_block, :weight_lines, :value_text, :primary_median_voters

    def self.mcp_url = "#{::Api::Host.base_url}/api/mcp/admin"

    def initialize(domain:, queue:)
      raise ArgumentError, "unknown queue #{queue.inspect}" unless QUEUES.include?(queue.to_sym)

      @domain = domain.to_s
      @queue = queue.to_sym
    end

    def call
      return unless file.exist?

      ERB.new(file.read).result_with_hash(
        {mcp_url: self.class.mcp_url}.merge(counts)
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
      when :author_verdicts then {pending_authors: ::Books::RepairVerdict.current.reimport_author.proposed.count}
      when :row_moves then {pending_row_moves: ::Books::RepairVerdict.current.reimport_row.proposed.count}
      when :series then series_counts
      when :book_submissions then book_submission_counts
      else decision_counts
      end
    end

    # The proposed re-import matches by confidence, as the page's default view
    # shows them with kind=reimport_match.
    def repair_verdict_counts
      pending = ::Books::RepairVerdict.current.reimport_match.proposed.group(:confidence).count
      %w[high medium low].to_h { |level| [:"pending_#{level}", pending[level].to_i] }
    end

    # The queue page's tabs, so the prompt and the page say the same numbers.
    def book_submission_counts
      counts = ::Services::Books::BookSubmissions::QueueTabs.counts
      {pending_review: counts["needs_review"], pending_details: counts["needs_details"], needs_human: counts["needs_human"]}
    end

    # The live (not deleted, not merged away) series, how many hold a single book,
    # and how many books sit in more than one of them.
    def series_counts
      live = ::Books::Series.active
      links = ::Books::SeriesBook.where(series_id: live.select(:id))
      {
        live_series: live.count,
        single_book_series: links.group(:series_id).having("COUNT(*) = 1").count.size,
        books_in_several_series: links.group(:book_id).having("COUNT(*) > 1").count.size
      }
    end

    # What the queue shows: pairs naming a book the Goodreads re-import is emptying are hidden there, so not counted.
    def duplicate_counts
      models = ::DataImporters::FinderRegistry.for_domain(@domain).map(&:model)
      pending = ::Services::DuplicateCandidates::BeingRebuilt.exclude(::DuplicateCandidate.pending.where(item_type: models))
        .group(:item_type).count
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
