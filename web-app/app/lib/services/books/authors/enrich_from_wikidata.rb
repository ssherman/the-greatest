# frozen_string_literal: true

module Services
  module Books
    module Authors
      # One Wikidata run for one author (spec §5, §6, §13). Resolve; on a
      # match, apply the item, link its Wikipedia article and check any
      # legacy Wikipedia description; on a miss, deprecate those
      # descriptions. Exactly one books.author_wikidata ledger row per run,
      # skips and failures included, tied to the run's decision. A Wikimedia
      # failure writes a failed row and returns; a rate limit propagates so
      # the job can reschedule.
      class EnrichFromWikidata
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.author_wikidata"
        PROVIDER = "wikidata"
        # "Done" outcomes. A failed or skipped run leaves the author to be tried again.
        PROCESSED = %w[applied nothing_to_apply unrecognized].freeze
        LEDGER_CONFIDENCE = {"certain" => "high", "high" => "high", "medium" => "medium", "low" => "low"}.freeze

        def self.call(author:, refresh: false, client: nil, wikipedia_client: nil)
          new(author: author, refresh: refresh, client: client, wikipedia_client: wikipedia_client).call
        end

        def initialize(author:, refresh:, client:, wikipedia_client:)
          @author = author
          @refresh = refresh
          @client = client || ::Wikidata::Client.new
          @wikipedia_client = wikipedia_client
          @decision = nil
          @facts = nil
        end

        def call
          return finish(:skipped, write(outcome: :skipped, reason: "placeholder")) if author.exclude_from_rankings?
          return finish(:skipped, write(outcome: :skipped, reason: "already_processed")) if !refresh && processed?

          resolved = ResolveWikidata.call(author: author, refresh: refresh, client: @client).data
          @decision = resolved[:decision]
          case resolved[:outcome]
          when :matched then matched(resolved[:entity], resolved[:redirected_ids])
          when :unmatched then unmatched
          else finish(:failed, write(outcome: :failed, reason: "resolve_failed", error: resolved[:reason]))
          end
        rescue ::Wikimedia::Exceptions::Error => e
          finish(:failed, write(outcome: :failed, reason: "wikimedia_error", error: "#{e.class.name.demodulize}: #{e.message}",
            facts: @facts || {}))
        end

        private

        attr_reader :author, :refresh

        # "Newer than the author row": after the production re-migration an
        # author is re-created with its id, and the old rows no longer count.
        def processed?
          author.enrichments.for_kind(KIND).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at).exists?
        end

        def matched(entity, redirected_ids)
          applied = ApplyWikidata.call(author: author, entity: entity, decision: @decision, client: @client,
            redirected_ids: redirected_ids)
          @facts = applied.data[:facts]
          if applied.data[:conflict]
            @decision.update!(needs_review: true)
            return finish(:matched, write(outcome: :nothing_to_apply, reason: "held_qid_conflict", recognized: true, facts: @facts))
          end

          wikipedia = LinkWikipedia.call(author: author, entity: entity, refresh: refresh, client: @wikipedia_client)
          @facts["wikipedia"] = wikipedia.data[:fact]
          legacy = CleanLegacyWikipedia.call(author: author, entity: entity, refresh: refresh, client: @wikipedia_client)
          @facts["legacy_wikipedia"] = legacy if legacy
          changed = applied.data[:applied].any? || wikipedia.data[:fact]["applied"] || legacy&.dig("applied")
          citations = ["https://www.wikidata.org/wiki/#{entity.id}", wikipedia.data[:lead]&.url].compact
          finish(:matched, write(outcome: changed ? :applied : :nothing_to_apply, reason: "matched #{entity.id}",
            recognized: true, facts: @facts, citations: citations))
        end

        def unmatched
          legacy = CleanLegacyWikipedia.call(author: author, entity: nil, refresh: refresh, client: @wikipedia_client)
          facts = legacy ? {"legacy_wikipedia" => legacy} : {}
          finish(:unmatched, write(outcome: :unrecognized, reason: "no_match", recognized: false, facts: facts))
        end

        def write(outcome:, reason:, recognized: nil, facts: {}, citations: [], error: nil)
          author.enrichments.create!(
            kind: KIND, provider: PROVIDER, outcome: outcome, reason: reason, recognized: recognized,
            confidence: LEDGER_CONFIDENCE[@decision&.confidence], facts: facts, citations: citations,
            error: error, match_decision: @decision
          )
        end

        def finish(outcome, row)
          Result.new(success?: outcome != :failed, data: {outcome: outcome, enrichment: row, decision: @decision},
            errors: Array(row.error))
        end
      end
    end
  end
end
