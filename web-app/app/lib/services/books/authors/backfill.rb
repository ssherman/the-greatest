# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The backfill (spec §13). Plans an author enrichment run for every author
      # the Wikidata step has not processed (LedgerRun.processed; a placeholder
      # never is, so placeholders are left out): ranked authors first by
      # rank, then the rest by how many books they wrote. Each run's Wikidata
      # step starts SPACING seconds after the one before, the Wikidata pace, with
      # research off for the whole run.
      #
      # An author whose Wikidata step missed and whose VIAF step never
      # finished (a failure, or a job lost) gets a run that starts at the VIAF
      # step. When that author's AI step already ran this era (a
      # books.author_facts row newer than the author row) the run is told so
      # (skip_ai_if_ran), so a VIAF match queues the AI step again only through
      # the forced Wikidata hop; a lost chain, whose AI step never ran, runs it
      # after VIAF's own miss.
      #
      # An author with an active run, or a chain job still waiting in Sidekiq
      # from before the workflow shipped, is left out, so a second backfill
      # while the first is still running plans no one twice. The limit applies
      # to each kind after that.
      class Backfill
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        SPACING = 6

        def self.call(limit:, queued: nil)
          new(limit: limit, queued: queued).call
        end

        def self.unprocessed
          ::Books::Author.where(exclude_from_rankings: false)
            .where.not(id: LedgerRun.processed(EnrichFromWikidata::KIND).select(:enrichable_id))
        end

        def initialize(limit:, queued:)
          @limit = limit
          @queued = queued
          @left_out = 0
        end

        def call
          waiting = (@queued || QueuedChain.author_ids) | active_run_author_ids
          wikidata = take(ranked(self.class.unprocessed).pluck(:id), waiting)
          viaf = take(viaf_retries.order(:id).pluck(:id), waiting)

          authors = ::Books::Author.where(id: wikidata + viaf).index_by(&:id)
          wikidata.each_with_index do |id, index|
            ::Workflows::Books::AuthorEnrichment.start(authors.fetch(id), initiated_by: "backfill",
              options: {allow_research: false}, start_after: (index * SPACING).seconds.from_now)
          end
          # The ledger test for "the AI step already ran" is the run's own
          # skip_if, evaluated when its turn comes, not a set computed here.
          viaf.each do |id|
            ::Workflows::Books::AuthorEnrichment.start(authors.fetch(id), initiated_by: "backfill",
              options: {allow_research: false, start_at: "viaf", skip_ai_if_ran: true})
          end

          Result.new(success?: true, errors: [], data: {
            wikidata: wikidata.size, viaf: viaf.size, left_out: @left_out,
            wikidata_done_at: Time.current + (wikidata.size * SPACING).seconds
          })
        end

        private

        def active_run_author_ids
          ::WorkflowRun.running.where(workflow: ::Workflows::Books::AuthorEnrichment.workflow).pluck(:enrichable_id).to_set
        end

        def take(ids, waiting)
          fresh = ids.reject { |id| waiting.include?(id) }
          @left_out += ids.size - fresh.size
          @limit ? fresh.first(@limit) : fresh
        end

        def ranked(scope)
          configuration = ::Books::Authors::RankingConfiguration.default_primary
          rank_join = ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN ranked_items ON ranked_items.item_type = 'Books::Author' " \
            "AND ranked_items.item_id = books_authors.id AND ranked_items.ranking_configuration_id = ?",
            configuration&.id
          ])
          counts = ::Books::BookAuthor.where(role: :author).group(:author_id).select("author_id, COUNT(*) AS books")
          scope.joins(rank_join)
            .joins("LEFT JOIN (#{counts.to_sql}) book_counts ON book_counts.author_id = books_authors.id")
            .order(Arel.sql("ranked_items.rank ASC NULLS LAST, COALESCE(book_counts.books, 0) DESC, books_authors.id ASC"))
        end

        def viaf_retries
          wikidata = LedgerRun.processed(EnrichFromWikidata::KIND)
          ::Books::Author.where(exclude_from_rankings: false)
            .where(id: wikidata.where(outcome: :unrecognized).select(:enrichable_id))
            .where.not(id: wikidata.where(outcome: %w[applied nothing_to_apply]).select(:enrichable_id))
            .where.not(id: LedgerRun.processed(EnrichFromViaf::KIND).select(:enrichable_id))
        end
      end
    end
  end
end
