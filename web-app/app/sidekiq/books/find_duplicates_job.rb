# frozen_string_literal: true

# The duplicate sweep (spec §16): resolve one ranked book against the rest
# of the catalog by calling the finder with the book's own fields, verify on
# (no identifier early exit) and the book itself excluded. A match means
# another local book is the same work; the pair is raised as bulk_verify.
# Nothing else is written and no provider runs.
#
# One book per job on the serial queue: each /resolve saturates the Open
# Library service, and a Sidekiq restart mid-sweep then loses one book, not
# the sweep. Re-running is safe for pairs (a pending pair gains an
# occurrence, a dismissed one is never re-raised); it does write a fresh
# match_decisions row per book.
class Books::FindDuplicatesJob
  include Sidekiq::Job

  # A retried book writes a second match_decisions row (accepted -- see the
  # class comment above on re-running).
  sidekiq_options queue: :serial, retry: 3

  # Raised when the finder's Open Library source failed, so Sidekiq retries
  # the book instead of the job silently recording a decision made without
  # it.
  class SourceFailed < StandardError; end

  QUERY_IDENTIFIERS = {
    isbn13: "books_work_isbn13",
    isbn10: "books_work_isbn10",
    asin: "books_work_asin",
    goodreads_id: "books_work_goodreads_id",
    open_library_work_key: "books_work_openlibrary_id"
  }.freeze

  # A ranked book can carry dozens of identifiers per type (the #1 book has
  # 107). The sweep wants OTHER local books, and a few values per type give
  # the identifier source its collision evidence without 100 lookups per
  # job or a /resolve body the service was never timed against.
  IDENTIFIERS_PER_TYPE = 3

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

    match = DataImporters::Books::Book::Finder.new.call(query: query_for(book), verify: true, subject: book, exclude: book)
    # The Open Library source is what finds a translation held under
    # another title (spec §16); a decision made without it is not the
    # sweep's answer. Raising lets Sidekiq retry the book -- a retry writes
    # a fresh match_decisions row, which is accepted (see sidekiq_options).
    # This check comes before the matched? early return so a degraded
    # match is never flagged.
    if match.sources_failed.include?("open_library")
      raise SourceFailed, "Open Library source failed for Books::Book##{book.id}: #{match.reason}"
    end
    return unless match.matched?

    Services::DuplicateCandidates::Flag.call(
      item_type: "Books::Book",
      ids: [book.id, match.record.id],
      source: :bulk_verify,
      evidence: {reason: match.reason, decided_by: match.decided_by.to_s, confidence: match.confidence.to_s},
      match_decision: match.decision
    )
  end

  private

  def query_for(book)
    by_type = book.identifiers.group_by(&:identifier_type)
    values = ->(type) { Array(by_type[type]).map(&:value) }

    DataImporters::Books::Book::ImportQuery.new(
      title: book.title,
      author_names: book.authors.map(&:name),
      year: book.first_published_year,
      isbn13: values.call(QUERY_IDENTIFIERS[:isbn13]).first(IDENTIFIERS_PER_TYPE),
      isbn10: values.call(QUERY_IDENTIFIERS[:isbn10]).first(IDENTIFIERS_PER_TYPE),
      asin: values.call(QUERY_IDENTIFIERS[:asin]).first(IDENTIFIERS_PER_TYPE),
      goodreads_id: values.call(QUERY_IDENTIFIERS[:goodreads_id]).first(IDENTIFIERS_PER_TYPE),
      open_library_work_key: values.call(QUERY_IDENTIFIERS[:open_library_work_key]).first
    )
  end
end
