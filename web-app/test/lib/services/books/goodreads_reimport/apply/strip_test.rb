# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class StripTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @book.identifiers.where(identifier_type: :books_work_isbn13).delete_all
          end

          def verdict(value: "9780000000001")
            ::Books::RepairVerdict.create!(kind: :reimport_strip, subject_key: "reimport:strip:#{@book.id}:books_work_isbn13:#{value}",
              decided_by: :rule, status: :approved,
              payload: {"book_id" => @book.id, "identifier_type" => "books_work_isbn13", "value" => value})
          end

          test "removes a legacy identifier and keeps what it held in the payload" do
            identifier = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780000000001", source: :legacy)
            verdict = verdict()

            result = Strip.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_not Identifier.exists?(identifier.id)
            removed = verdict.reload.payload["removed"].first
            assert_equal [identifier.id, "9780000000001", "legacy"], removed.values_at("id", "value", "source")
          end

          test "ignores an identifier that is not legacy" do
            identifier = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780000000001", source: :open_library)

            result = Strip.call(verdict: verdict)

            assert_equal [:noop, false], result.data.values_at(:outcome, :final)
            assert Identifier.exists?(identifier.id)
          end

          test "an identifier that is already gone is a final noop" do
            result = Strip.call(verdict: verdict)

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
          end

          test "an applied verdict is not applied twice" do
            verdict = verdict()
            verdict.update!(applied_at: Time.current)

            assert_equal :noop, Strip.call(verdict: verdict).data[:outcome]
          end
        end
      end
    end
  end
end
