# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Makes provisional books and authors part of the catalog and queues
      # their enrichment (Goodreads import spec §10, Approve steps 2–3). A
      # promoted book takes its provisional authors with it: the catalog never
      # shows a book whose author is hidden. update! reindexes each record.
      #
      # Enrichment as the importer queues it for a new book: a book credited to
      # an author promoted here waits for that author's chain (a deferral
      # ledger row; Books::Authors::EnrichJob hands it on), any other book is
      # enriched at once, and every promoted author starts its chain. Jobs are
      # queued after commit, so a chain never runs before the deferral exists.
      class PromoteRecords
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(books:, authors:)
          new(books: books, authors: authors).call
        end

        def initialize(books:, authors:)
          @books = Array(books).select(&:provisional?)
          @authors = Array(authors)
        end

        def call
          authors = (@authors + @books.flat_map(&:authors)).uniq.select(&:provisional?)
          author_ids = authors.map(&:id).to_set
          enrich_now = []
          ActiveRecord::Base.transaction(requires_new: true) do
            authors.each { |author| author.update!(provisional: false) }
            @books.each do |book|
              book.update!(provisional: false)
              if book.book_authors.any? { |book_author| author_ids.include?(book_author.author_id) }
                ::Services::Books::DeferredEnrichment.defer!(book)
              else
                enrich_now << book.id
              end
            end
          end
          ActiveRecord.after_all_transactions_commit do
            author_ids.each { |id| ::Books::Authors::WikidataJob.perform_async(id) }
            enrich_now.each { |id| ::Books::EnrichBookJob.perform_async(id) }
          end
          Result.new(success?: true, data: {book_ids: @books.map(&:id), author_ids: author_ids.to_a}, errors: [])
        end
      end
    end
  end
end
