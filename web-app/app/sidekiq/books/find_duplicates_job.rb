# frozen_string_literal: true

# Drives the duplicate sweep (Services::Books::FindDuplicates) one book per
# job on the serial queue: each /resolve saturates the Open Library
# service, and a Sidekiq restart mid-sweep then loses one book, not the
# sweep.
class Books::FindDuplicatesJob
  include Sidekiq::Job

  # A retried book writes a second match_decisions row (accepted -- the
  # service's pairs are safe to re-raise).
  sidekiq_options queue: :serial, retry: 3

  # Raised when the sweep could not get its answer (the finder's Open
  # Library source failed), so Sidekiq retries the book instead of the job
  # silently completing on a decision made without it.
  class SourceFailed < StandardError; end

  # Enqueues one job per book in the primary ranking, best rank first.
  # Returns how many were enqueued.
  def self.enqueue_ranked(limit: nil)
    config = Books::RankingConfiguration.default_primary
    raise "No primary Books::RankingConfiguration; nothing to sweep" if config.nil?

    scope = RankedItem.where(ranking_configuration_id: config.id, item_type: "Books::Book").where.not(rank: nil).order(:rank)
    scope = scope.limit(limit) if limit
    ids = scope.pluck(:item_id)
    ids.each_slice(1000) { |slice| perform_bulk(slice.zip) }
    ids.size
  end

  def perform(book_id)
    book = Books::Book.includes(:authors, :identifiers).find_by(id: book_id)
    return if book.nil?

    result = Services::Books::FindDuplicates.call(book: book)
    raise SourceFailed, result.errors.join("; ") unless result.success?
  end
end
