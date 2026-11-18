# frozen_string_literal: true

module Services
  module Books
    # Turns one BookFactsTask answer into the facts written on a book and one
    # books.book_facts Enrichment row. EnrichBook calls it for the paid runs;
    # the agent queue calls it for an agent's answer. The answer has Symbol
    # keys at every level and :recognized present.
    #
    # hold_low_confidence is the reason to record a low overall confidence
    # under instead of applying it. strict_review makes a description whose
    # review call failed raise ReviewFailed before anything is written, so a
    # retrying caller does not keep a half-applied answer.
    class RecordBookFacts
      KIND = "books.book_facts"

      class ReviewFailed < StandardError; end

      def self.call(...)
        new(...).call
      end

      def initialize(book:, facts:, mode:, citations: [], ai_chat: nil, provider: nil, model: nil, author_names: nil,
        goodreads_page: nil, hold_low_confidence: nil, strict_review: false, extra_facts: {})
        @book = book
        @facts = facts
        @mode = mode
        @citations = citations
        @ai_chat = ai_chat
        @provider = provider
        @model = model
        @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
        @goodreads_page = goodreads_page
        @hold_low_confidence = hold_low_confidence
        @strict_review = strict_review
        @extra_facts = extra_facts
      end

      def call
        confidence = confidence_for(facts[:confidence])

        if facts[:recognized] == false
          return book.enrichments.create!(
            row_attributes.merge(
              outcome: :unrecognized,
              recognized: false,
              confidence: confidence,
              facts: unapplied_facts(facts, reason: "unrecognized").merge(extra_facts),
              citations: citations
            )
          )
        end

        # A low-confidence knowledge answer is a guess about to be checked by
        # the paid research run. Applying it first would leave research able
        # only to fill blanks, so its facts are recorded and deferred; research
        # applies what it verifies. When the budget is gone and research will
        # not run, the guess is the best we have and is applied as usual.
        if hold_low_confidence && confidence == "low"
          return book.enrichments.create!(
            row_attributes.merge(
              outcome: :nothing_to_apply,
              recognized: true,
              confidence: confidence,
              facts: unapplied_facts(facts, reason: hold_low_confidence).merge(extra_facts),
              citations: citations
            )
          )
        end

        description = description_for(facts.dig(:description, :value), mode)
        applied = ApplyBookFacts.call(book: book, facts: facts, citations: citations, description: description)

        book.enrichments.create!(
          row_attributes.merge(
            outcome: applied.data[:applied].any? ? :applied : :nothing_to_apply,
            recognized: facts[:recognized],
            confidence: confidence,
            facts: applied.data[:facts].merge(extra_facts),
            citations: citations
          )
        )
      end

      private

      attr_reader :book, :facts, :mode, :citations, :ai_chat, :provider, :model, :goodreads_page,
        :hold_low_confidence, :strict_review, :extra_facts

      def author_names
        @author_names.presence || book.authors.map(&:name)
      end

      def row_attributes
        {kind: KIND, mode: mode, ai_chat: ai_chat, provider: provider, model: model}
      end

      def confidence_for(value)
        normalized = value.to_s.strip.downcase
        Enrichment.confidences.key?(normalized) ? normalized : nil
      end

      # Every fact recorded, none applied: "unrecognized" when the model did
      # not know the book and was guessing, "deferred" when a low-confidence
      # answer is about to be checked by research.
      def unapplied_facts(facts, reason:)
        facts.except(:recognized, :confidence).to_h do |name, fact|
          entry = fact.is_a?(Hash) ? {"value" => fact[:value], "confidence" => fact[:confidence]} : {"value" => fact, "confidence" => nil}
          [name.to_s, entry.merge("applied" => false, "reason" => reason)]
        end
      end

      # nil when there is no description to review or apply. When the book
      # already has an ai_generated description, the applier would record
      # already_set regardless, so the review call (123k of 158k production
      # books carry a legacy AI description) is skipped and that reason is
      # reported directly.
      def description_for(text, mode)
        return nil if text.blank?
        return {text: text, review: nil, reason: "already_set"} if book.descriptions.any? { |d| d.source == "ai_generated" }

        review_description(text, mode)
      end

      # {text:, review:, reason:}; a reason means "do not write". The
      # reviewer's verdict is binding: a reply with no spoilers verdict at
      # all (an empty response) is review_failed, same as a call that
      # errored outright; a spoiler flag or any style violation with no
      # rewrite to fall back on is a rejection, not a pass-through of the
      # text the reviewer just objected to. DescriptionCheck only covers the
      # violations a regex can see, so it cannot stand in for the reviewer.
      def review_description(text, mode)
        review = Services::Ai::Tasks::Books::DescriptionReviewTask.new(parent: book, description: text, author_names: author_names).call
        return review_failed(text) unless review.success?

        data = review.data.deep_symbolize_keys
        return review_failed(text) if data[:spoilers].nil?

        flagged = data[:spoilers] == true || Array(data[:style_violations]).any?
        if flagged && data[:rewritten].blank?
          check = DescriptionCheck.call(text)
          return {text: check.data[:text], review: review_verdict(data, check), reason: "rejected"}
        end

        reviewed = data[:rewritten].presence || text
        check = if mode == :sourced
          DescriptionCheck.call(reviewed, source_text: goodreads_page.description, exempt_phrases: [book.title, *author_names])
        else
          DescriptionCheck.call(reviewed)
        end

        {
          text: check.data[:text],
          review: review_verdict(data, check),
          reason: check.success? ? nil : "rejected"
        }
      end

      def review_failed(text)
        raise ReviewFailed, "the description review failed" if strict_review

        {text: text, review: nil, reason: "review_failed"}
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
    end
  end
end
