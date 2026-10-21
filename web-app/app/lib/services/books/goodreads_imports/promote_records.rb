# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Makes provisional books and authors part of the catalog and plans
      # their enrichment (Goodreads import spec §10, Approve steps 2–3). A
      # promoted book takes its provisional authors with it: the catalog never
      # shows a book whose author is hidden. update! reindexes each record.
      #
      # Enrichment is planned as the importer plans it for a new book
      # (Workflows::Books::BookEnrichment): each promoted book gets a run whose
      # book_facts waits on the author runs of the authors promoted with it,
      # and a promoted author credited to no promoted book gets an author run
      # of its own. The plan rows are written in the transaction below, so a
      # failure there leaves none; the dispatch waits for the commit. A record
      # that already has an active run joins it instead of getting a second.
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
          goal_urls = []
          credited_to_a_book = Set.new
          on_favorites = false
          ActiveRecord::Base.transaction(requires_new: true) do
            authors.each { |author| author.update!(provisional: false) }
            @books.each do |book|
              book.update!(provisional: false)
              # Only the authors promoted with this book: it waits on those,
              # and the others have their own book, or their own run below.
              credited = book.book_authors.map(&:author_id).select { |id| author_ids.include?(id) }
              credited_to_a_book.merge(credited)
              ::Workflows::Books::BookEnrichment.start(book, initiated_by: "goodreads_promote", new_author_ids: credited)
              # Public goal pages count catalog books only, so a promoted
              # book's readers' pages change; at the new count these URLs
              # cover the old pages too.
              goal_urls.concat(::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: book))
            end
            authors.reject { |author| credited_to_a_book.include?(author.id) }.each do |author|
              ::Workflows::Books::AuthorEnrichment.start(author, initiated_by: "goodreads_promote")
            end
            on_favorites = @books.any? &&
              ::UserListItem.joins(:user_list).merge(::Books::UserList.favorites).where(listable: @books).exists?
          end
          ActiveRecord.after_all_transactions_commit do
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
