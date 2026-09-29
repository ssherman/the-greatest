# frozen_string_literal: true

module Services
  module Books
    module Authors
      # One VIAF run for one author (spec §8, §11). Resolve; on a match,
      # apply the cluster. Exactly one books.author_viaf ledger row per run,
      # skips and failures included, tied to the run's decision. A VIAF
      # failure writes a failed row and returns. RateLimited (VIAF paused,
      # blocked, or our pace busy) propagates so the job reschedules: every
      # VIAF call happens before the decision is recorded, so nothing is
      # written and the rescheduled run starts clean, resuming from the
      # suggestions and clusters already stored.
      class EnrichFromViaf
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.author_viaf"
        PROVIDER = "viaf"
        # "Done" outcomes. A failed or skipped run leaves the author to be tried again.
        PROCESSED = %w[applied nothing_to_apply unrecognized].freeze
        LEDGER_CONFIDENCE = {"certain" => "high", "high" => "high", "medium" => "medium", "low" => "low"}.freeze

        def self.call(author:, refresh: false, client: nil)
          new(author: author, refresh: refresh, client: client).call
        end

        def initialize(author:, refresh:, client:)
          @author = author
          @refresh = refresh
          @client = client
          @decision = nil
          @wikidata_qid = nil
        end

        def call
          return finish(:skipped, write(outcome: :skipped, reason: "placeholder")) if author.exclude_from_rankings?
          return finish(:skipped, write(outcome: :skipped, reason: "already_processed")) if !refresh && processed?

          resolved = ResolveViaf.call(author: author, refresh: refresh, client: @client).data
          @decision = resolved[:decision]
          case resolved[:outcome]
          when :matched then matched(resolved[:person])
          when :unmatched then finish(:unmatched, write(outcome: :unrecognized, reason: "no_match", recognized: false))
          else finish(:failed, write(outcome: :failed, reason: "resolve_failed", error: resolved[:reason]))
          end
        rescue ::Viaf::Exceptions::Error => e
          finish(:failed, write(outcome: :failed, reason: "viaf_error", error: "#{e.class.name.demodulize}: #{e.message}"))
        end

        private

        attr_reader :author, :refresh

        # "Newer than the author row": after the production re-migration an
        # author is re-created with its id, and the old rows no longer count.
        def processed?
          author.enrichments.for_kind(KIND).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at).exists?
        end

        def matched(person)
          applied = ApplyViaf.call(author: author, person: person, decision: @decision)
          facts = applied.data[:facts]
          if applied.data[:conflict]
            @decision.update!(needs_review: true)
            return finish(:matched, write(outcome: :nothing_to_apply, reason: "held_viaf_conflict", recognized: true, facts: facts))
          end

          @wikidata_qid = applied.data[:wikidata_qid]
          outcome = applied.data[:applied].any? ? :applied : :nothing_to_apply
          finish(:matched, write(outcome: outcome, reason: "matched #{person.viaf_id}", recognized: true, facts: facts,
            citations: ["https://viaf.org/viaf/#{person.viaf_id}"]))
        end

        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          author.enrichments.create!(
            kind: KIND, provider: PROVIDER, outcome: outcome, reason: reason, recognized: recognized,
            confidence: LEDGER_CONFIDENCE[@decision&.confidence], facts: facts, citations: citations,
            error: error, match_decision: @decision
          )
        end

        def finish(outcome, row)
          Result.new(success?: outcome != :failed,
            data: {outcome: outcome, enrichment: row, decision: @decision, wikidata_qid: @wikidata_qid},
            errors: Array(row.error))
        end
      end
    end
  end
end
