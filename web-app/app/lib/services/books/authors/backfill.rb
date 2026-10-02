# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The backfill (spec §13). Queues the author chain for every author the
      # Wikidata step has not processed (LedgerRun.processed; a placeholder
      # never is, so placeholders are left out): ranked authors first by
      # rank, then the rest by how many books they wrote. Each WikidataJob
      # starts SPACING seconds after the one before, the Wikidata pace, with
      # research off for the whole chain.
      #
      # An author whose Wikidata step missed and whose VIAF step never
      # finished (a failure, or a job lost) gets the VIAF step again. Its AI
      # step already ran, so the job is told so (enrich_queued) and queues
      # it again only through the Wikidata hop, when VIAF finds an item.
      #
      # An author with a chain job already waiting in Sidekiq is left out,
      # so a second run while the first is still scheduled queues no one
      # twice: a duplicate would skip the Wikidata step and pay for the AI
      # step again. The limit applies to each kind after that.
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
          waiting = @queued || QueuedChain.author_ids
          wikidata = take(ranked(self.class.unprocessed).pluck(:id), waiting)
          viaf = take(viaf_retries.order(:id).pluck(:id), waiting)

          wikidata.each_with_index do |id, index|
            ::Books::Authors::WikidataJob.perform_in(index * SPACING, id, false, false, false)
          end
          viaf.each { |id| ::Books::Authors::ViafJob.perform_async(id, false, true, false) }

          Result.new(success?: true, errors: [], data: {
            wikidata: wikidata.size, viaf: viaf.size, left_out: @left_out,
            wikidata_done_at: Time.current + (wikidata.size * SPACING).seconds
          })
        end

        private

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
