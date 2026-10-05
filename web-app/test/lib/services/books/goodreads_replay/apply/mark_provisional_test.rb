require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class MarkProvisionalTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @verdict = ::Books::RepairVerdict.create!(kind: :mark_provisional, subject_key: "book:#{@book.id}",
              decided_by: :rule, status: :approved, payload: {"book_id" => @book.id, "reason" => "authorless"})
          end

          test "flags the book, queues its reindex, and names the rankings to recalculate" do
            assert_difference(-> { SearchIndexRequest.where(parent: @book).count }, 1) do
              @result = MarkProvisional.call(verdict: @verdict)
            end

            assert_equal :applied, @result.data[:outcome]
            assert @book.reload.provisional
            default = ::Books::RankingConfiguration.default_primary
            assert_includes @result.data[:ranking_configuration_ids], default.id if default
          end

          test "a book already provisional is a no-op" do
            @book.update!(provisional: true)

            assert_equal :noop, MarkProvisional.call(verdict: @verdict).data[:outcome]
          end

          test "revert clears the flag it set" do
            MarkProvisional.call(verdict: @verdict)

            result = MarkProvisional.revert(verdict: @verdict)

            assert_equal :applied, result.data[:outcome]
            refute @book.reload.provisional
          end

          test "a deleted book is a no-op either way" do
            @verdict.payload["book_id"] = 0

            assert_equal "book 0 no longer exists", MarkProvisional.call(verdict: @verdict).data[:reason]
            assert_equal "book 0 no longer exists", MarkProvisional.revert(verdict: @verdict).data[:reason]
          end
        end
      end
    end
  end
end
