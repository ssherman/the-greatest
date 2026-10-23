# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module AlternateTitles
      class ReportTest < ActiveSupport::TestCase
        test "counts and samples" do
          book = books_books(:got)
          AlternateTitle.create!(titleable: book, title: "Bad One", source: :legacy, status: :removed,
            verdict: :not_same_work, category: :junk, confidence: 0.95, reason: "not the book", decided_by: :ai)
          AlternateTitle.create!(titleable: book, title: "Admin Pick", source: :admin, status: :review,
            verdict: :not_same_work, category: :other_work, confidence: 0.9, reason: "maybe another", decided_by: :ai)
          total = AlternateTitle.where(titleable_type: "Books::Book").count

          report = Report.call

          assert_kind_of String, report
          assert_includes report, "Bad One"
          assert_includes report, "Admin Pick"
          assert_includes report, "maybe another"
          assert_includes report, book.title
          assert_match(/admin rows in review: 1/i, report)
          assert_match(/total: #{total}/i, report)
          assert_match(/junk: #{AlternateTitle.where(titleable_type: "Books::Book").category_junk.count}/, report)
        end
      end
    end
  end
end
