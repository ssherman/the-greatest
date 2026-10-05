# frozen_string_literal: true

module Books
  module GoodreadsReplay
    # One replay edition, one pass (Goodreads import spec §12.3).
    # - Pass one runs on low: there are ~188k editions, each at most one fast
    #   AI call.
    # - Pass two, with Open Library /resolve (5-6 s), runs one at a time on
    #   serial, and only for editions pass one could not settle.
    # Re-running is safe: pass one skips an edition whose replay rows all have
    # findings, and every write is an upsert of a finding or a verdict.
    class ResolveEditionJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 3

      BATCH = 1_000

      def self.replay_rows
        ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay)
          .where.not(goodreads_edition_id: nil)
      end

      def self.enqueue_pending
        first = replay_rows.where(replay_finding: nil).distinct.pluck(:goodreads_edition_id)
        full = replay_rows.replay_awaiting_full_pass.distinct.pluck(:goodreads_edition_id) - first
        first.each_slice(BATCH) { |ids| perform_bulk(ids.map { |id| [id, 1] }) }
        full.each_slice(BATCH) { |ids| set(queue: :serial).perform_bulk(ids.map { |id| [id, 2] }) }
        {first_pass: first.size, full_pass: full.size}
      end

      def perform(edition_id, pass = 1)
        edition = ::Books::GoodreadsEdition.find_by(id: edition_id)
        return unless edition
        return if pass == 1 && !self.class.replay_rows.where(goodreads_edition_id: edition.id, replay_finding: nil).exists?

        result = ::Services::Books::GoodreadsReplay::ResolveEdition.call(edition: edition, pass: pass)
        self.class.set(queue: :serial).perform_async(edition.id, 2) if pass == 1 && result.data[:needs_full_pass]
      end
    end
  end
end
