# frozen_string_literal: true

module Services
  module Books
    # A book whose enrichment waits for the authors its import created (spec
    # §10): their countries do not exist yet, and the book's origin country
    # should come from them. The wait is a skipped books.book_facts ledger
    # row; the author chain's last step (Books::Authors::EnrichJob) hands the
    # book on once the author is enriched. Only a book that waited is handed
    # on, never the author's other books (Shane, 2026-09-30).
    class DeferredEnrichment
      REASON = "deferred_to_authors"

      def self.defer!(book)
        book.enrichments.create!(kind: EnrichBook::KIND, outcome: :skipped, reason: REASON)
      end

      # The author's books whose latest books.book_facts row is the
      # deferral: a book enriched since has a newer row.
      def self.waiting_book_ids(author)
        book_ids = author.book_authors.pluck(:book_id)
        return [] if book_ids.empty?

        ::Enrichment.where(enrichable_type: "Books::Book", enrichable_id: book_ids, kind: EnrichBook::KIND)
          .select("DISTINCT ON (enrichable_id) enrichable_id, reason")
          .order(:enrichable_id, created_at: :desc, id: :desc)
          .filter_map { |row| row.enrichable_id if row.reason == REASON }
      end
    end
  end
end
