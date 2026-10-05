require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FindBookDuplicatesTest < ActiveSupport::TestCase
        setup do
          ::DuplicateCandidate.where(item_type: "Books::Book").delete_all
          @author = books_authors(:tolstoy)
          @older = book("Hadji Murat")
          @newer = book("Hadji  Murat")
          ::Identifier.create!(identifiable: @older, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Identifier.create!(identifiable: @newer, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@older.id, @newer.id], source: :ai)
        end

        def book(title, authors: [@author])
          ::Books::Book.create!(title: title).tap do |created|
            authors.each { |author| ::Books::BookAuthor.create!(book: created, author: author) }
          end
        end

        test "same title, same authors and a shared identifier is an approved merge into the older book" do
          assert_equal 1, FindBookDuplicates.call.data[:recorded]

          verdict = ::Books::RepairVerdict.merge_books.sole
          assert_equal "books:#{[@older.id, @newer.id].min}:#{[@older.id, @newer.id].max}", verdict.subject_key
          assert_equal [@newer.id, @older.id], [verdict.payload["source_id"], verdict.payload["target_id"]]
          assert_equal [["books_work_isbn13", "9780812969849"]], verdict.payload["shared"]
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_rule?
        end

        test "no shared identifier, a different author or a different title leaves the pair to the duplicates queue" do
          ::Identifier.where(identifiable: @newer).delete_all
          assert_equal 0, FindBookDuplicates.call.data[:recorded]

          other = book("Hadji Murat", authors: [books_authors(:king)])
          ::Identifier.create!(identifiable: other, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@older.id, other.id], source: :ai)
          renamed = book("Hadji Murad")
          ::Identifier.create!(identifiable: renamed, identifier_type: :books_work_isbn13, value: "9780812969849")
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [@older.id, renamed.id], source: :ai)

          assert_equal 0, FindBookDuplicates.call.data[:recorded]
          assert_equal 0, ::Books::RepairVerdict.count
        end

        test "a dismissed or merged pair is not checked" do
          ::DuplicateCandidate.where(item_type: "Books::Book").sole.update!(status: :not_duplicate)

          assert_equal 0, FindBookDuplicates.call.data[:recorded]
        end

        test "finds only; merges nothing" do
          assert_no_difference(-> { ::Books::Book.count }) { FindBookDuplicates.call }
        end
      end
    end
  end
end
