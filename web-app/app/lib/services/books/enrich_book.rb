# frozen_string_literal: true

module Services
  module Books
    # Runs the book facts task, reviews the description, applies the facts,
    # and decides whether a web-search run is warranted. Writes exactly one
    # Enrichment row per run, including skips and failures.
    #
    # Spec: docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §6.
    class EnrichBook
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      KIND = RecordBookFacts::KIND

      def self.call(book:, force_research: false, author_names: nil, goodreads_page: nil)
        new(book: book, force_research: force_research, author_names: author_names, goodreads_page: goodreads_page).call
      end

      def initialize(book:, force_research:, author_names:, goodreads_page: nil)
        @book = book
        @goodreads_page = goodreads_page
        @force_research = force_research
        @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
        @rows = []
      end

      def call
        unless inputs_present?
          rows << skip("missing_inputs", mode: :knowledge)
          return result
        end

        # A matched Goodreads page replaces the knowledge run and its paid
        # research fallback (spec section 6); only force_research still researches.
        first_mode = if force_research
          :research
        elsif goodreads_page
          :sourced
        elsif past_cutoff?
          :research
        else
          :knowledge
        end

        if first_mode == :research && !force_research && budget_exhausted?
          rows << skip("budget_exhausted", mode: :research)
          return result
        end

        rows << run(first_mode)
        return result if rows.last.failed?

        if first_mode == :knowledge && needs_research?(rows.last)
          rows << if budget_exhausted? && !force_research
            skip("budget_exhausted", mode: :research)
          else
            run(:research)
          end
        end

        result
      end

      private

      attr_reader :book, :force_research, :goodreads_page, :rows

      def author_names
        @author_names.presence || book.authors.map(&:name)
      end

      def inputs_present?
        book.title.present? && author_names.any?
      end

      def past_cutoff?
        year = book.first_published_year
        year.present? && year >= Rails.application.config.x.ai.knowledge_cutoff_year
      end

      def needs_research?(row)
        row.recognized == false || (row.recognized && row.confidence_low?)
      end

      def budget_exhausted?
        Enrichment.against_research_cap.count >= Rails.application.config.x.ai.research_daily_cap
      end

      def run(mode)
        task_result = Services::Ai::Tasks::Books::BookFactsTask.new(parent: book, mode: mode, author_names: author_names, source: goodreads_page).call
        return failed_row(mode, task_result) unless task_result.success?

        facts = task_result.data[:facts].deep_symbolize_keys
        # BaseStrategy parses an empty reply to {}; without :recognized there
        # is nothing to act on, so this is a failure, not a recognized run
        # with every fact null.
        return failed_row(mode, task_result, error: "empty response") unless facts.key?(:recognized)

        chat = task_result.ai_chat
        citations = Array(task_result.data[:citations])

        RecordBookFacts.call(
          book: book, facts: facts, mode: mode, citations: citations,
          ai_chat: chat, provider: chat&.provider, model: chat&.model,
          author_names: author_names, goodreads_page: goodreads_page,
          hold_low_confidence: ("deferred" if mode == :knowledge && !budget_exhausted?)
        )
      rescue => e
        # Anything past this point that raises (a unique-index race between
        # concurrent jobs, a bug in ApplyBookFacts) must still leave exactly
        # one ledger row, and the job needs to see a failure to retry.
        book.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message))
      end

      def failed_row(mode, task_result, error: task_result.error)
        role = Services::Ai::Roles.resolve((mode == :research) ? :research : :standard)
        book.enrichments.create!(
          kind: KIND,
          mode: mode,
          outcome: :failed,
          error: error,
          provider: role.provider.to_s,
          model: role.model,
          ai_chat: task_result.ai_chat
        )
      end

      def row_attributes(mode, chat)
        {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
      end

      def skip(reason, mode:)
        book.enrichments.create!(kind: KIND, mode: mode, outcome: :skipped, reason: reason)
      end

      def result
        failures = rows.select(&:failed?)
        Result.new(success?: failures.empty?, data: {enrichments: rows}, errors: failures.map(&:error))
      end
    end
  end
end
