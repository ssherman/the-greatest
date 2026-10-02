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
        include LedgerRun

        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.author_viaf"
        PROVIDER = "viaf"

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

          @restored = RestoreIdentifier.call(author: author, finder: ResolveViaf)
          resolved = ResolveViaf.call(author: author, refresh: refresh, client: @client).data
          @decision = resolved[:decision]
          case resolved[:outcome]
          when :matched then matched(resolved[:person])
          when :unmatched then finish(:unmatched, write(outcome: :unrecognized, reason: "no_match", recognized: false))
          else finish(:failed, write(outcome: :failed, reason: "resolve_failed", error: resolved[:reason]))
          end
        rescue ::Viaf::Exceptions::RateLimited
          # A busy pace or a pause (Paused is a RateLimited) is a request to
          # wait, not a failure, and neither is a Viaf::Exceptions::Error:
          # without this clause the catch-all below would swallow it.
          raise
        rescue ::Viaf::Exceptions::Error => e
          finish(:failed, write(outcome: :failed, reason: "viaf_error", error: "#{e.class.name.demodulize}: #{e.message}"))
        rescue => e
          finish(:failed, unexpected(e))
        end

        private

        attr_reader :author, :refresh

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

        def finish(outcome, row)
          Result.new(success?: outcome != :failed,
            data: {outcome: outcome, enrichment: row, decision: @decision, wikidata_qid: @wikidata_qid},
            errors: Array(row.error))
        end
      end
    end
  end
end
