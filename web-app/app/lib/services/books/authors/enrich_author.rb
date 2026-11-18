# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The AI step for one author (spec §9). The facts task runs on the
      # standard role, grounded in the records the author steps matched
      # (MatchedRecords). Web research follows only for an author no
      # authority matched whom the model did not know or knew poorly, within
      # the shared daily cap. The description is checked in code, reviewed
      # on the fast role, and rewritten at most once. One books.author_facts
      # ledger row per task run, skips and failures included; each row that
      # called the model names the records in its input.
      class EnrichAuthor
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = RecordAuthorFacts::KIND
        HUMAN_SOURCES = %w[ai_generated manual].freeze

        def self.call(author:, allow_research: true, force_research: false, context: nil)
          new(author: author, allow_research: allow_research, force_research: force_research, context: context).call
        end

        def initialize(author:, allow_research:, force_research: false, context: nil)
          @author = author
          @allow_research = allow_research
          @force_research = force_research
          @context = context
          @records = MatchedRecords.new(author)
          @rows = []
        end

        def call
          return skipped("placeholder") if author.exclude_from_rankings?
          return forced_research if force_research
          return skipped("complete") if complete?

          rows << run(:knowledge)
          return result if rows.last.failed?

          if research_wanted?(rows.last)
            reason = research_skip_reason
            rows << (reason ? skip_research(reason) : run(:research))
          end
          result
        end

        private

        attr_reader :author, :allow_research, :force_research, :context, :records, :rows

        # The paid worker: the research run at once, with no knowledge call, no
        # completeness skip and no budget or mode check.
        def forced_research
          rows << run(:research)
          result
        end

        def skipped(reason)
          rows << skip(reason, mode: :knowledge)
          result
        end

        # Nothing left to fill (spec §9). death_year is left out because a
        # living author has none; "unspecified" is the legacy AI's "don't
        # know", so it counts as blank. A deprecated description (a rejected
        # link's, spec §12) does not count.
        def complete?
          author.birth_year.present? && ApplyAuthorFacts::GENDERS.include?(author.gender) &&
            author.author_countries.exists? && author.descriptions.any? { |row| HUMAN_SOURCES.include?(row.source) && !row.deprecated? }
        end

        def research_allowed? = allow_research && !records.matched?

        def research_wanted?(row)
          research_allowed? && (row.recognized == false || (row.recognized && row.confidence_low?))
        end

        def budget_exhausted?
          ::Enrichment.against_research_cap.count >= Rails.application.config.x.ai.research_daily_cap
        end

        # Why the web search will not run, or nil when it will. In queue mode
        # the search is left to an agent.
        def research_skip_reason
          return nil if force_research
          return "queued" if ::Services::EnrichmentQueue::ResearchRoute.queue?

          "budget_exhausted" if budget_exhausted?
        end

        # The skip row goes first: the queue type's still_needed? reads it.
        def skip_research(reason)
          row = skip(reason, mode: :research)
          ::Services::EnrichmentQueue::ResearchRoute.defer(kind: KIND, record: author) if reason == "queued"
          row
        end

        # Hold a low-confidence knowledge answer while research is still to
        # follow. The cheap checks come first so the budget COUNT and the queue
        # lookup only run for an answer that is low.
        def hold_reason(mode, facts)
          return nil unless mode == :knowledge && facts[:confidence].to_s.strip.downcase == "low"
          return nil unless research_allowed?

          "deferred" if research_will_follow?
        end

        def research_will_follow?
          if ::Services::EnrichmentQueue::ResearchRoute.queue?
            ::Services::EnrichmentQueue::ResearchRoute.open_for?(kind: KIND, record: author)
          else
            !budget_exhausted?
          end
        end

        def run(mode)
          task_result = ::Services::Ai::Tasks::Books::AuthorFactsTask.new(parent: author, records: records, mode: mode).call
          return failed_row(mode, task_result) unless task_result.success?

          facts = task_result.data[:facts].deep_symbolize_keys
          # An empty reply parses to {}; without :recognized there is nothing to act on.
          return failed_row(mode, task_result, error: "empty response") unless facts.key?(:recognized)

          chat = task_result.ai_chat
          RecordAuthorFacts.call(
            author: author, records: records, facts: facts, mode: mode,
            citations: Array(task_result.data[:citations]), ai_chat: chat, provider: chat&.provider, model: chat&.model,
            hold_low_confidence: hold_reason(mode, facts), extra_facts: context_facts
          )
        rescue => e
          # Whatever raises past the task call (a bug in the applier, a
          # constraint) still leaves exactly one row, and the job sees a failure.
          author.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message, facts: failed_facts))
        end

        # The context goes on every row with facts or a failure, so the research
        # cap can tell a queue worker's run from an importer's.
        def context_facts
          context ? {"context" => QueueTypes::LedgerEntries.input(context)} : {}
        end

        def failed_facts = RecordAuthorFacts.sources_fact(records).merge(context_facts)

        def row_attributes(mode, chat)
          {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
        end

        def failed_row(mode, task_result, error: task_result.error)
          role = ::Services::Ai::Roles.resolve((mode == :research) ? :research : :standard)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :failed, error: error, provider: role.provider.to_s,
            model: role.model, ai_chat: task_result.ai_chat, facts: failed_facts)
        end

        def skip(reason, mode:)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :skipped, reason: reason)
        end

        def result
          failures = rows.select(&:failed?)
          Result.new(success?: failures.empty?, data: {enrichments: rows}, errors: failures.map(&:error))
        end
      end
    end
  end
end
