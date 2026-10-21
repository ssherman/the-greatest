# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Plans the book's enrichment (books enrichment workflows spec, section
        # 10): an author run for each author this import created and one book
        # run whose book_facts waits on those authors. It replaces the three
        # providers that queued the book AI job, the Wikidata job and the
        # Amazon job.
        #
        # Runs after Authors, and the importer saves the book after each
        # successful provider, so the book's book_authors rows are in the
        # database by now; BookEnrichment.start reads them from there to decide
        # which created authors the book waits on.
        #
        # The plan rows are written here, inside the caller's transaction: a
        # rollback (the list wizard's CreateFailed, Goodreads' CreateBook) takes
        # them with it, and a crash after the commit cannot lose them. Only the
        # dispatch waits for the outermost commit, and BookEnrichment.start
        # arranges that.
        class Enrichment < DataImporters::ProviderBase
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end

          def populate(book, query:, match: nil)
            return failure_result(errors: ["Book title required for AI enrichment"]) if book.title.blank?

            # The linked authors normally exist by now; the query's author names
            # are only the fallback, used when none could be linked.
            author_names = book.authors.map(&:name)
            author_names = Array(query&.author_names).map(&:to_s).reject(&:blank?) if author_names.empty?
            return failure_result(errors: ["Book must have an author for AI enrichment"]) if author_names.empty?
            return failure_result(errors: ["Book must be persisted before queuing AI enrichment"]) unless book.persisted?

            # A savepoint of its own: a failure after the author runs were
            # written takes the whole plan with it, so the failure result below
            # never leaves half a plan in the caller's transaction.
            ::ActiveRecord::Base.transaction(requires_new: true) do
              ::Workflows::Books::BookEnrichment.start(book, initiated_by: "importer",
                new_author_ids: @new_author_ids.uniq, author_names: author_names)
            end
            success_result(data_populated: [:enrichment_planned])
          rescue => e
            failure_result(errors: ["Enrichment provider error: #{e.message}"])
          end
        end
      end
    end
  end
end
