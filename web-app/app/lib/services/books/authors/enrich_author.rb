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

        KIND = "books.author_facts"
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
        # know", so it counts as blank.
        def complete?
          author.birth_year.present? && ApplyAuthorFacts::GENDERS.include?(author.gender) &&
            author.author_countries.exists? && author.descriptions.any? { |row| HUMAN_SOURCES.include?(row.source) }
        end

        def research_allowed? = allow_research && !records.matched?

        def research_wanted?(row)
          research_allowed? && (row.recognized == false || (row.recognized && row.confidence_low?))
        end

        def budget_exhausted?
          ::Enrichment.research.today.count >= Rails.application.config.x.ai.research_daily_cap
        end

        def run(mode)
          task_result = ::Services::Ai::Tasks::Books::AuthorFactsTask.new(parent: author, records: records, mode: mode).call
          return failed_row(mode, task_result) unless task_result.success?

          facts = task_result.data[:facts].deep_symbolize_keys
          # An empty reply parses to {}; without :recognized there is nothing to act on.
          return failed_row(mode, task_result, error: "empty response") unless facts.key?(:recognized)

          chat = task_result.ai_chat
          citations = Array(task_result.data[:citations])
          confidence = confidence_for(facts[:confidence])

          if facts[:recognized] == false
            return write(mode, chat, outcome: :unrecognized, recognized: false, confidence: confidence,
              facts: unapplied_facts(facts, reason: "unrecognized"), citations: citations)
          end

          # A low-confidence answer about to be checked by research is
          # recorded, not applied, as EnrichBook does: applied first, it would
          # leave research only blanks to fill.
          if mode == :knowledge && confidence == "low" && research_allowed? && !budget_exhausted?
            return write(mode, chat, outcome: :nothing_to_apply, recognized: true, confidence: confidence,
              facts: unapplied_facts(facts, reason: "deferred"), citations: citations)
          end

          description = description_for(facts[:description])
          applied = ApplyAuthorFacts.call(author: author, facts: facts, citations: citations, description: description)
          write(mode, chat, outcome: applied.data[:applied].any? ? :applied : :nothing_to_apply, recognized: true,
            confidence: confidence, facts: applied.data[:facts], citations: citations)
        rescue => e
          # Whatever raises past the task call (a bug in the applier, a
          # constraint) still leaves exactly one row, and the job sees a failure.
          author.enrichments.create!(row_attributes(mode, chat).merge(outcome: :failed, error: e.message, facts: sources_fact))
        end

        # nil when there is nothing to review or apply. An author who already
        # has an AI description would get already_set from the applier, so
        # the review call is skipped and that reason is reported directly. A
        # low-confidence fact is never written by ApplyAuthorFacts either, so
        # it is reported the same way, skipping the review call and the code
        # check that would otherwise run before it (Ruling: a review of a
        # fact that will not be applied just spends a fast-role call).
        def description_for(fact)
          text = fact && fact[:value]
          return nil if text.blank?
          return {text: text, review: nil, reason: "low_confidence"} if fact[:confidence].to_s.strip.casecmp?("low")
          return {text: text, review: nil, reason: "already_set"} if author.descriptions.any? { |row| row.source == "ai_generated" }

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
          first = ::Services::Books::DescriptionCheck.call(text, source_text: source, exempt_phrases: exempt_titles)
          review = ::Services::Ai::Tasks::Books::AuthorDescriptionReviewTask.new(
            parent: author, description: first.data[:text], source_text: source, flagged: first.errors
          ).call
          return {text: first.data[:text], review: nil, reason: "review_failed"} unless review.success?

          data = review.data.to_h.deep_symbolize_keys
          return {text: first.data[:text], review: nil, reason: "review_failed"} if data[:style_violations].nil?

          if (data[:style_violations].any? || first.errors.any?) && data[:rewritten].blank?
            return {text: first.data[:text], review: verdict(data, first), reason: "rejected"}
          end

          final = ::Services::Books::DescriptionCheck.call(data[:rewritten].presence || first.data[:text], source_text: source, exempt_phrases: exempt_titles)
          {text: final.data[:text], review: verdict(data, first, final), reason: final.success? ? nil : "rejected"}
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

        def write(mode, chat, facts:, **attributes)
          author.enrichments.create!(row_attributes(mode, chat).merge(attributes).merge(facts: facts.merge(sources_fact)))
        end

        # The records whose content went into the task's input (spec §9), so
        # a rejected link can find what it influenced (§12).
        def sources_fact
          {"sources" => {"value" => records.sources, "applied" => false, "reason" => "input"}}
        end

        def row_attributes(mode, chat)
          {kind: KIND, mode: mode, ai_chat: chat, provider: chat&.provider, model: chat&.model}
        end

        def failed_row(mode, task_result, error: task_result.error)
          role = ::Services::Ai::Roles.resolve((mode == :research) ? :research : :standard)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :failed, error: error, provider: role.provider.to_s,
            model: role.model, ai_chat: task_result.ai_chat, facts: sources_fact)
        end

        def skip(reason, mode:)
          author.enrichments.create!(kind: KIND, mode: mode, outcome: :skipped, reason: reason)
        end

        def confidence_for(value)
          normalized = value.to_s.strip.downcase
          ::Enrichment.confidences.key?(normalized) ? normalized : nil
        end

        # Every fact recorded under its ledger name, none applied.
        def unapplied_facts(facts, reason:)
          facts.except(:recognized, :confidence).to_h do |name, fact|
            entry = fact.is_a?(Hash) ? {"value" => fact[:value], "confidence" => fact[:confidence]} : {"value" => fact, "confidence" => nil}
            [ApplyAuthorFacts::LEDGER_NAMES.fetch(name, name).to_s, entry.merge("applied" => false, "reason" => reason)]
          end
        end

        def result
          failures = rows.select(&:failed?)
          Result.new(success?: failures.empty?, data: {enrichments: rows}, errors: failures.map(&:error))
        end
      end
    end
  end
end
