# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class CreateBookTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :resolving)
        end

        test "creates a provisional, unverified book from the edition and records everything it made" do
          edition = goodreads_edition(goodreads_book_id: 90_000_001, isbn13: "9780441013593", original_publication_year: 1977)
          match = unmatched_match(subject: edition)

          result = CreateBook.call(edition: edition, import: @import, match: match)

          edition.reload
          book = edition.book
          author = book.authors.sole
          assert_equal :created, result.data[:outcome]
          assert_equal ["The Quiet Year", 1977, true], [book.title, book.first_published_year, book.provisional?]
          assert_equal ["Anna Brenner", true], [author.name, author.provisional?]
          assert_equal [["books_work_goodreads_id", "90000001"], ["books_work_isbn13", "9780441013593"]],
            book.identifiers.map { |identifier| [identifier.identifier_type, identifier.value] }.sort
          assert_equal [true, true], [edition.created?, edition.verification_unverified?]
          assert_equal match.decision, edition.match_decision
          assert_equal book, match.decision.reload.record
          expected = [["Books::Book", book.id], ["Books::Author", author.id]] +
            book.book_authors.map { |link| ["Books::BookAuthor", link.id] } +
            book.identifiers.map { |identifier| ["Identifier", identifier.id] }
          assert_equal expected.sort, @import.records.map { |record| [record.record_type, record.record_id] }.sort
          assert @import.records.all?(&:created?)
        end

        test "an existing author is linked, never made provisional, never recorded as created" do
          edition = goodreads_edition(title: "Hadji Murat", primary_author: "Leo Tolstoy")

          CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition))

          tolstoy = books_authors(:tolstoy)
          assert_equal [tolstoy], edition.reload.book.authors.to_a
          assert_not tolstoy.reload.provisional?
          assert_not @import.records.exists?(record_type: "Books::Author", record_id: tolstoy.id)
        end

        test "an edition another import resolved while this one waited is left as it is" do
          edition = goodreads_edition
          match = unmatched_match(subject: edition)
          ::Books::GoodreadsEdition.where(id: edition.id)
            .update_all(book_id: books_books(:war_and_peace).id, resolution: 0, resolved_at: Time.current)
          importer = mock("importer")
          importer.expects(:call).never

          result = CreateBook.call(edition: edition, import: @import, match: match, importer: importer)

          assert_equal [:cached, books_books(:war_and_peace)], [result.data[:outcome], edition.reload.book]
        end

        test "a book created for the same signature since the finder looked is adopted" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: book, resolution: :created, resolved_at: Time.current)
          edition = goodreads_edition(goodreads_book_id: 90_000_011)
          importer = mock("importer")
          importer.expects(:call).never

          result = CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition), importer: importer)

          edition.reload
          assert_equal [:matched, book, true], [result.data[:outcome], edition.book, edition.matched?]
        end

        test "a book the finder already considered and turned down is not adopted" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: book, resolution: :created, resolved_at: Time.current)
          edition = goodreads_edition(goodreads_book_id: 90_000_011)
          considered = ::DataImporters::Candidate.new(record: book, sources: [:exact])

          result = CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition, candidates: [considered]))

          assert_equal :created, result.data[:outcome]
          assert_not_equal book, edition.reload.book
        end

        test "a same-signature edition that was matched, not created, is not adopted" do
          goodreads_edition(goodreads_book_id: 90_000_010, book: books_books(:war_and_peace), resolution: :matched,
            resolved_at: Time.current)
          edition = goodreads_edition(goodreads_book_id: 90_000_011)

          result = CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition))

          assert_equal :created, result.data[:outcome]
          assert_not_equal books_books(:war_and_peace), edition.reload.book
        end

        test "a book left without an author is rolled back and the edition stays unresolved" do
          ::DataImporters::Books::Author::Importer.stubs(:call).raises(RuntimeError, "author lookup down")
          edition = goodreads_edition

          assert_no_difference("::Books::Book.count") do
            assert_raises(CreateBook::CreateFailed) do
              CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition))
            end
          end
          assert_nil edition.reload.resolved_at
        end

        test "an importer that makes no book raises and leaves nothing behind" do
          edition = goodreads_edition
          failing = Object.new
          def failing.call(**)
            ::DataImporters::ImportResult.new(item: ::Books::Book.new, provider_results: [], success: false)
          end

          assert_raises(CreateBook::CreateFailed) do
            CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition), importer: failing)
          end
          assert_nil edition.reload.resolved_at
          assert_equal 0, @import.records.count
        end

        test "with its Goodreads page, the book takes the page's title and authors, and the edition is verified" do
          edition = goodreads_edition(goodreads_book_id: 90_000_001, original_publication_year: 1977, pending_import: @import,
            verification: :pending)
          page = goodreads_page(goodreads_book_id: 90_000_001, title: "The Quiet Year: A Novel", isbn13: "9780441013593")

          CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition), page: page,
            author_names: ["Anna Brenner", "Jo Ray"])

          edition.reload
          book = edition.book
          assert_equal ["The Quiet Year: A Novel", 1977, true], [book.title, book.first_published_year, book.provisional?]
          assert_equal ["Anna Brenner", "Jo Ray"], book.authors.map(&:name).sort
          assert_includes book.identifiers.map { |identifier| [identifier.identifier_type, identifier.value] },
            ["books_work_isbn13", "9780441013593"]
          assert_equal [true, true, nil], [edition.created?, edition.verification_verified?, edition.pending_import_id]
        end
      end
    end
  end
end
