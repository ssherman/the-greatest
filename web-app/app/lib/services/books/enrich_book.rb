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

      KIND = "books.book_facts"

      def self.call(book:, force_research: false, author_names: nil)
        new(book: book, force_research: force_research, author_names: author_names).call
      end

      def initialize(book:, force_research:, author_names:)
        @book = book
        @force_research = force_research
        @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
        @rows = []
      end

      def call
        unless inputs_present?
          rows << skip("missing_inputs", mode: :knowledge)
          return result
        end

        first_mode = (force_research || past_cutoff?) ? :research : :knowledge

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

      attr_reader :book, :force_research, :rows

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
        Enrichment.research.today.count >= Rails.application.config.x.ai.research_daily_cap
      end

      def run(mode)
        task_result = Services::Ai::Tasks::Books::BookFactsTask.new(parent: book, mode: mode, author_names: author_names).call
        return failed_row(mode, task_result) unless task_result.success?

        facts = task_result.data[:facts].deep_symbolize_keys
        # BaseStrategy parses an empty reply to {}; without :recognized there
        # is nothing to act on, so this is a failure, not a recognized run
        # with every fact null.
        return failed_row(mode, task_result, error: "empty response") unless facts.key?(:recognized)

        chat = task_result.ai_chat
        citations = Array(task_result.data[:citations])

        if facts[:recognized] == false
          return book.enrichments.create!(
            row_attributes(mode, chat).merge(
              outcome: :unrecognized,
              recognized: false,
              confidence: confidence_for(facts[:confidence]),
              facts: unapplied_facts(facts),
              citations: citations
            )
          )
        end

        description = review_description(facts.dig(:description, :value))
        applied = ApplyBookFacts.call(book: book, facts: facts, citations: citations, description: description)

        book.enrichments.create!(
          row_attributes(mode, chat).merge(
            outcome: applied.data[:applied].any? ? :applied : :nothing_to_apply,
            recognized: facts[:recognized],
            confidence: confidence_for(facts[:confidence]),
            facts: applied.data[:facts],
            citations: citations
          )
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

      def confidence_for(value)
        normalized = value.to_s.strip.downcase
        Enrichment.confidences.key?(normalized) ? normalized : nil
      end

      # A model that does not know the book is guessing at whatever it did
      # return, so nothing is applied; the facts are still kept for the record.
      def unapplied_facts(facts)
        facts.except(:recognized, :confidence).to_h do |name, fact|
          entry = fact.is_a?(Hash) ? {"value" => fact[:value], "confidence" => fact[:confidence]} : {"value" => fact, "confidence" => nil}
          [name.to_s, entry.merge("applied" => false, "reason" => "unrecognized")]
        end
      end

      # nil when there is no description to review. Otherwise
      # {text:, review:, reason:}; a reason means "do not write". The
      # reviewer's verdict is binding: a reply with no spoilers verdict at
      # all (an empty response) is review_failed, same as a call that
      # errored outright; a spoiler flag with no rewrite to fall back on is
      # a rejection, not a pass-through of the unreviewed text.
      def review_description(text)
        return nil if text.blank?

        review = Services::Ai::Tasks::Books::DescriptionReviewTask.new(parent: book, description: text, author_names: author_names).call
        return {text: text, review: nil, reason: "review_failed"} unless review.success?

        data = review.data.deep_symbolize_keys
        return {text: text, review: nil, reason: "review_failed"} if data[:spoilers].nil?

        if data[:spoilers] == true && data[:rewritten].blank?
          check = DescriptionCheck.call(text, book: book)
          return {text: check.data[:text], review: review_verdict(data, check), reason: "rejected"}
        end

        reviewed = data[:rewritten].presence || text
        check = DescriptionCheck.call(reviewed, book: book)

        {
          text: check.data[:text],
          review: review_verdict(data, check),
          reason: check.success? ? nil : "rejected"
        }
      end

      def review_verdict(data, check)
        {
          "spoilers" => data[:spoilers],
          "spoiler_notes" => data[:spoiler_notes],
          "style_violations" => Array(data[:style_violations]),
          "rewritten" => data[:rewritten].present?,
          "check_errors" => check.errors
        }
      end

      def result
        failures = rows.select(&:failed?)
        Result.new(success?: failures.empty?, data: {enrichments: rows}, errors: failures.map(&:error))
      end
    end
  end
end
