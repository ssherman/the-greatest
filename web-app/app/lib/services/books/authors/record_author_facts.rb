# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Turns one AuthorFactsTask answer into the facts written on an author
      # and one books.author_facts Enrichment row. EnrichAuthor calls it for
      # the paid runs; the agent queue calls it for an agent's answer. The
      # answer has Symbol keys at every level and :recognized present.
      #
      # hold_low_confidence is the reason to record a low overall confidence
      # under instead of applying it. strict_review makes a description whose
      # review call failed raise ReviewFailed before anything is written, so a
      # retrying caller does not keep a half-applied answer. A raise from here
      # propagates; the caller decides what row it leaves.
      class RecordAuthorFacts
        KIND = "books.author_facts"

        class ReviewFailed < StandardError; end

        # The records whose content went into the task's input (spec §9), so
        # a rejected link can find what it influenced (§12).
        def self.sources_fact(records)
          {"sources" => {"value" => records.sources, "applied" => false, "reason" => "input"}}
        end

        def self.call(...)
          new(...).call
        end

        def initialize(author:, records:, facts:, mode:, citations: [], ai_chat: nil, provider: nil, model: nil,
          hold_low_confidence: nil, strict_review: false, extra_facts: {})
          @author = author
          @records = records
          @facts = facts
          @mode = mode
          @citations = citations
          @ai_chat = ai_chat
          @provider = provider
          @model = model
          @hold_low_confidence = hold_low_confidence
          @strict_review = strict_review
          @extra_facts = extra_facts
        end

        def call
          confidence = confidence_for(facts[:confidence])

          if facts[:recognized] == false
            return write(outcome: :unrecognized, recognized: false, confidence: confidence,
              facts: unapplied_facts(facts, reason: "unrecognized"), citations: citations)
          end

          # A low overall confidence is recorded, not applied, when the caller
          # names a reason to hold it, as RecordBookFacts does. The paid
          # enricher holds a low-confidence knowledge answer under "deferred"
          # while research is still to follow: applied first, it would leave
          # research only blanks to fill. The agent queue holds a low overall
          # confidence under "low_confidence", and nothing is written.
          if hold_low_confidence && confidence == "low"
            return write(outcome: :nothing_to_apply, recognized: true, confidence: confidence,
              facts: unapplied_facts(facts, reason: hold_low_confidence), citations: citations)
          end

          description = description_for(facts[:description])
          applied = ApplyAuthorFacts.call(author: author, facts: facts, citations: citations, description: description)
          write(outcome: applied.data[:applied].any? ? :applied : :nothing_to_apply, recognized: true,
            confidence: confidence, facts: applied.data[:facts], citations: citations)
        end

        private

        attr_reader :author, :records, :facts, :mode, :citations, :ai_chat, :provider, :model,
          :hold_low_confidence, :strict_review, :extra_facts

        # nil when there is nothing to review or apply. An author who already has a
        # non-deprecated AI description would get already_set from the applier, so the
        # review call is skipped and that reason is reported directly. A
        # low-confidence fact is never written by ApplyAuthorFacts either, so it is
        # reported the same way, skipping the review call and the code check that
        # would otherwise run before it (Ruling: a review of a fact that will not be
        # applied just spends a fast-role call).
        def description_for(fact)
          text = fact && fact[:value]
          return nil if text.blank?
          return {text: text, review: nil, reason: "low_confidence"} if fact[:confidence].to_s.strip.casecmp?("low")
          return {text: text, review: nil, reason: "already_set"} if author.descriptions.any? { |row| row.source == "ai_generated" && !row.deprecated? }

          review_description(text)
        end

        # {text:, review:, reason:}; a reason means "do not write". The code
        # check runs first and its findings go to the reviewer, so a draft
        # that fails only the code check still gets its one rewrite (spec
        # §9). The rewrite is checked again; a second failure is rejected. A
        # reply with no style_violations at all is an empty answer, the same
        # as a failed call.
        def review_description(text)
          source = records.lead&.extract
          first = ::Services::Books::DescriptionCheck.call(text, source_text: source, exempt_phrases: exempt_titles,
            min_words: ::Services::Ai::Tasks::Books::AuthorFactsTask::MIN_WORDS)
          review = ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.new(
            parent: author, description: first.data[:text], source_text: source, flagged: first.errors
          ).call
          return review_failed(first.data[:text]) unless review.success?

          data = review.data.to_h.deep_symbolize_keys
          return review_failed(first.data[:text]) if data[:style_violations].nil?

          if (data[:style_violations].any? || first.errors.any?) && data[:rewritten].blank?
            return {text: first.data[:text], review: verdict(data, first), reason: "rejected"}
          end

          final = ::Services::Books::DescriptionCheck.call(data[:rewritten].presence || first.data[:text], source_text: source, exempt_phrases: exempt_titles,
            min_words: ::Services::Ai::Tasks::Books::AuthorFactsTask::MIN_WORDS)
          {text: final.data[:text], review: verdict(data, first, final), reason: final.success? ? nil : "rejected"}
        end

        def review_failed(text)
          raise ReviewFailed, "the description review failed" if strict_review

          {text: text, review: nil, reason: "review_failed"}
        end

        # Work titles the draft and the lead may both name (spec §9 asks for
        # best-known works named plainly): ours, and those the matched
        # records list. DescriptionCheck ignores the short ones.
        def exempt_titles
          @exempt_titles ||= begin
            works = [records.wikidata, records.viaf].compact
              .flat_map { |match| Array(match.evidence["matching_titles"]) + Array(match.evidence["other_titles"]) }
            (AuthorProfile.new(author).titles + works).compact_blank.uniq
          end
        end

        def verdict(data, first, final = nil)
          {
            "style_violations" => Array(data[:style_violations]),
            "rewritten" => data[:rewritten].present?,
            "check_errors" => first.errors,
            "final_check_errors" => final&.errors
          }.compact
        end

        def write(facts:, **attributes)
          author.enrichments.create!(
            {kind: KIND, mode: mode, ai_chat: ai_chat, provider: provider, model: model}
              .merge(attributes)
              .merge(facts: facts.merge(self.class.sources_fact(records)).merge(extra_facts))
          )
        end

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          ::Enrichment.confidences.key?(normalized) ? normalized : nil
        end

        # Every fact recorded under its ledger name, none applied, under the
        # given reason: "unrecognized" when the model did not know the author,
        # or the caller's hold reason for a low-confidence answer ("deferred"
        # from the paid enricher, "low_confidence" from the agent queue).
        def unapplied_facts(facts, reason:)
          facts.except(:recognized, :confidence).to_h do |name, fact|
            entry = fact.is_a?(Hash) ? {"value" => fact[:value], "confidence" => fact[:confidence]} : {"value" => fact, "confidence" => nil}
            [ApplyAuthorFacts::LEDGER_NAMES.fetch(name, name).to_s, entry.merge("applied" => false, "reason" => reason)]
          end
        end
      end
    end
  end
end
