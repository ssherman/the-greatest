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
          goal_urls = []
          on_favorites = false
          ActiveRecord::Base.transaction(requires_new: true) do
            authors.each { |author| author.update!(provisional: false) }
            @books.each do |book|
              book.update!(provisional: false)
              if book.book_authors.any? { |book_author| author_ids.include?(book_author.author_id) }
                ::Services::Books::DeferredEnrichment.defer!(book)
              else
                enrich_now << book.id
              end
              # Public goal pages count catalog books only, so a promoted
              # book's readers' pages change; at the new count these URLs
              # cover the old pages too.
              goal_urls.concat(::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: book))
            end
            on_favorites = @books.any? &&
              ::UserListItem.joins(:user_list).merge(::Books::UserList.favorites).where(listable: @books).exists?
          end
          ActiveRecord.after_all_transactions_commit do
            author_ids.each { |id| ::Books::Authors::WikidataJob.perform_async(id) }
            enrich_now.each { |id| ::Books::EnrichBookJob.perform_async(id) }
            if @books.any? || author_ids.any?
              ::Books::PurgeShowPagesJob.perform_async(@books.map(&:id), author_ids.to_a)
            end
            ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", goal_urls.uniq) if goal_urls.any?
            # The generated users' favorites list skips provisional books.
            ::GenerateUserFavoritesListsJob.perform_async("Books::UserList") if on_favorites
          end
          Result.new(success?: true, data: {book_ids: @books.map(&:id), author_ids: author_ids.to_a}, errors: [])
        end
      end
    end
  end
end
