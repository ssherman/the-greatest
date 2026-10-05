require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FixSlugIdentifiersTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @slug = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656-war-and-peace")
        end

        test "each slug-form Goodreads id becomes an approved, rule-certain strip_identifier verdict" do
          assert_equal 1, FixSlugIdentifiers.call.data[:recorded]

          verdict = ::Books::RepairVerdict.strip_identifier.sole
          assert_equal "book:#{@book.id}:books_work_goodreads_id:656-war-and-peace", verdict.subject_key
          assert_equal({"book_id" => @book.id, "remove" => [["books_work_goodreads_id", "656-war-and-peace"]],
                        "add" => [["books_work_goodreads_id", "656"]]}, verdict.payload)
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_rule?
          assert_predicate verdict, :confidence_certain?
        end

        test "bare ids are left alone, and running again records nothing new" do
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "1234")

          FixSlugIdentifiers.call
          FixSlugIdentifiers.call

          assert_equal 1, ::Books::RepairVerdict.count
        end

        test "changes nothing in the catalog" do
          FixSlugIdentifiers.call

          assert_equal "656-war-and-peace", @slug.reload.value
        end
      end
    end
  end
end
