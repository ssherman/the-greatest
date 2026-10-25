require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class PickCandidateTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @rows = (1..3).map do |n|
            ::Books::Goodreads::SearchPage::Row.new(goodreads_book_id: n, title: "War and Peace #{n}",
              author_names: ["Leo Tolstoy"], year: 1869, ratings_count: 100 - n, editions_count: n)
          end
        end

        def stub_task(index:, confidence: "high", success: true)
          result = ::Services::Ai::Result.new(success: success, error: ("boom" unless success),
            data: success ? {selected_index: index, confidence: confidence} : nil)
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.any_instance.stubs(:call).returns(result)
        end

        test "a high-confidence pick returns that row" do
          stub_task(index: 2)

          assert_equal 2, PickCandidate.call(book: @book, rows: @rows).goodreads_book_id
        end

        test "medium confidence returns nil" do
          stub_task(index: 2, confidence: "medium")

          assert_nil PickCandidate.call(book: @book, rows: @rows)
        end

        test "none selected returns nil" do
          stub_task(index: 0)

          assert_nil PickCandidate.call(book: @book, rows: @rows)
        end

        test "an index past the rows returns nil" do
          stub_task(index: 9)

          assert_nil PickCandidate.call(book: @book, rows: @rows)
        end

        test "an AI failure returns nil" do
          stub_task(index: nil, success: false)

          assert_nil PickCandidate.call(book: @book, rows: @rows)
        end

        test "only the top five rows are offered and the book is the parent" do
          many = (1..8).map { |n| @rows.first.with(goodreads_book_id: n) }
          ::Services::Ai::Tasks::Matching::SelectCandidateTask.expects(:new)
            .with(has_entries(entity_noun: "book", parent: @book)).with { |args| args[:candidate_lines].size == 5 }
            .returns(stub(call: ::Services::Ai::Result.new(success: true, data: {selected_index: 0, confidence: "high"})))

          assert_nil PickCandidate.call(book: @book, rows: many)
        end
      end
    end
  end
end
