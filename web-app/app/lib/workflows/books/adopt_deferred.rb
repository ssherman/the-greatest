# frozen_string_literal: true

# One-off (spec section 11, step 2): books that were deferred to their new
# authors before book enrichment became a workflow have no run. Their latest
# books.book_facts ledger row is still the deferral, and the old hand-off that
# would have released them only fires when an author chain ends, which for an
# author finished long ago is never. Plan the run they would have had.
#
# Only book_facts: the old flow never ran Amazon for these books, and this is
# an adoption, not a re-enrichment. A book waits on the AI step of every linked
# author that has an active run, and only those. An author with no run is
# deliberately not started here: the point is to release the book, not to
# re-enrich authors. Safe to run again: a book with a running book run is
# counted and left alone, and a book that has run has a newer ledger row.
module Workflows
  module Books
    class AdoptDeferred
      INITIATED_BY = "adopt_deferred"

      # limit caps the books planned (not the ones skipped), lowest id first.
      def self.call(limit: nil)
        candidate_ids = deferred_book_ids
        active_ids = WorkflowRun.running.where(workflow: BookEnrichment.workflow, enrichable_type: "Books::Book",
          enrichable_id: candidate_ids).pluck(:enrichable_id).to_set
        counts = {planned: 0, skipped_active: 0}

        ::Books::Book.where(id: candidate_ids).order(:id).find_each do |book|
          break if limit && counts[:planned] >= limit

          if active_ids.include?(book.id)
            counts[:skipped_active] += 1
          else
            BookEnrichment.start(book, initiated_by: INITIATED_BY, options: {only: ["book_facts"]},
              new_author_ids: waited_on_author_ids(book))
            counts[:planned] += 1
          end
        end
        counts
      end

      # The same DISTINCT ON as DeferredEnrichment.waiting_book_ids, over every
      # book: the latest row decides, so a book enriched since is not listed.
      def self.deferred_book_ids
        ::Enrichment.where(enrichable_type: "Books::Book", kind: ::Services::Books::EnrichBook::KIND)
          .select("DISTINCT ON (enrichable_id) enrichable_id, reason")
          .order(:enrichable_id, created_at: :desc, id: :desc)
          .filter_map { |row| row.enrichable_id if row.reason == ::Services::Books::DeferredEnrichment::REASON }
      end
      private_class_method :deferred_book_ids

      # BookEnrichment.start starts an author run for any id it is given, so
      # hand it only authors that already have a running one: starting one
      # would be a new enrichment, not the release of a waiting book.
      def self.waited_on_author_ids(book)
        running = WorkflowRun.running.where(workflow: AuthorEnrichment.workflow, enrichable_type: "Books::Author")
          .select(:enrichable_id)
        book.book_authors.where(author_id: running).pluck(:author_id)
      end
      private_class_method :waited_on_author_ids
    end
  end
end
