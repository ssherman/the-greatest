# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      # Two imports racing to create the same new book end with one book
      # (Goodreads import spec §5 "Locking", §14). Transactional tests are off:
      # each thread has its own connection, and one connection cannot see
      # another's rows inside a shared test transaction. Nothing rolls back,
      # so teardown deletes every row the test wrote.
      class CreateBookConcurrencyTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        self.use_transactional_tests = false

        TITLE = "The Concurrency Novel"
        AUTHOR = "Rae Racer"

        # Loaded with the class, before any thread starts: autoloading inside a
        # thread while this one holds the load interlock would deadlock.
        PRELOADED = [CreateBook, ::DataImporters::ImportResult, ::Books::GoodreadsImportRecord, ::Books::BookAuthor,
          ::Books::Author, ::Identifier, ::MatchDecision, ::SearchIndexRequest].freeze

        # Creates the book as the importer would. On its first call it reports
        # that, then waits to be released, holding its transaction (and so the
        # advisory lock) open.
        class PausingImporter
          def initialize(created:, release:)
            @created = created
            @release = release
            @calls = 0
            @mutex = Mutex.new
          end

          def call(title:, goodreads_id:, **)
            first = @mutex.synchronize { (@calls += 1) == 1 }
            book = ::Books::Book.create!(title: title, provisional: true)
            book.book_authors.create!(author: ::Books::Author.find_by!(name: "Leo Tolstoy"), position: 1)
            book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: goodreads_id.first)
            if first
              @created << true
              @release.pop(timeout: 10)
            end
            ::DataImporters::ImportResult.new(item: book, provider_results: [], success: true, created: true)
          end
        end

        setup do
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
          signature = ::Books::Goodreads::ExportRow.signature(TITLE, AUTHOR)
          @first = ::Books::GoodreadsEdition.create!(goodreads_book_id: 91_000_001, signature: signature, title: TITLE, primary_author: AUTHOR)
          @second = ::Books::GoodreadsEdition.create!(goodreads_book_id: 91_000_002, signature: signature, title: TITLE, primary_author: AUTHOR)
        end

        teardown do
          book_ids = ::Books::Book.where(title: TITLE).pluck(:id)
          ::Books::GoodreadsImportRecord.where(import_id: @import.id).delete_all
          ::Books::GoodreadsEdition.where(id: [@first.id, @second.id]).delete_all
          ::MatchDecision.where(subject_type: "Books::GoodreadsEdition", subject_id: [@first.id, @second.id]).delete_all
          ::Identifier.where(identifiable_type: "Books::Book", identifiable_id: book_ids).delete_all
          ::Books::BookAuthor.where(book_id: book_ids).delete_all
          ::SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book_ids).delete_all
          ::Books::Book.where(id: book_ids).delete_all
          ::Books::GoodreadsImport.where(id: @import.id).delete_all
        end

        test "two imports racing to create the same new book end with one book" do
          created = Thread::Queue.new
          release = Thread::Queue.new
          importer = PausingImporter.new(created: created, release: release)
          first_match = unmatched_match(subject: @first)
          second_match = unmatched_match(subject: @second)

          first = Thread.new { in_connection { CreateBook.call(edition: @first, import: @import, match: first_match, importer: importer) } }
          assert waiting { created.pop(timeout: 10) }, "the first import never reached its create"
          second = Thread.new { in_connection { CreateBook.call(edition: @second, import: @import, match: second_match, importer: importer) } }
          waiting { sleep 0.5 }
          assert second.alive?, "the second import did not wait for the first one's lock"

          release << true
          results = waiting { [first.value, second.value] }

          assert_equal [:created, :matched], results.map { |result| result.data[:outcome] }
          assert_equal 1, ::Books::Book.where(title: TITLE).count
          assert_equal @first.reload.book_id, @second.reload.book_id
        end

        private

        def in_connection(&block)
          ActiveRecord::Base.connection_pool.with_connection(&block)
        end

        def waiting(&block)
          ActiveSupport::Dependencies.interlock.permit_concurrent_loads(&block)
        end
      end
    end
  end
end
