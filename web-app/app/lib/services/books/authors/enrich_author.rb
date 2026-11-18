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

        def self.call(author:, allow_research: true)
          new(author: author, allow_research: allow_research).call
        end

        def initialize(author:, allow_research:)
          @author = author
          @allow_research = allow_research
          @records = MatchedRecords.new(author)
          @rows = []
        end

        def call
          return skipped("placeholder") if author.exclude_from_rankings?
          return skipped("complete") if complete?

          rows << run(:knowledge)
          return result if rows.last.failed?

          if research_wanted?(rows.last)
            rows << (budget_exhausted? ? skip("budget_exhausted", mode: :research) : run(:research))
          end
          result
        end

        private

        attr_reader :author, :allow_research, :records, :rows

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
            hold_low_confidence: ("deferred" if mode == :knowledge && research_allowed? && !budget_exhausted?)
          )
        rescue => e
          # Whatever raises past the task call (a bug in the applier, a
          # constraint) still leaves exactly one row, and the job sees a failure.
          author.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message, facts: RecordAuthorFacts.sources_fact(records)))
        end

        def row_attributes(mode, chat)
          {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
        end

        def failed_row(mode, task_result, error: task_result.error)
          role = ::Services::Ai::Roles.resolve((mode == :research) ? :research : :standard)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :failed, error: error, provider: role.provider.to_s,
            model: role.model, ai_chat: task_result.ai_chat, facts: RecordAuthorFacts.sources_fact(records))
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
