# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class SurveyReportTest < ActiveSupport::TestCase
        test "report counts and samples" do
          book = ::Books::Book.create!(title: "Hothouse")
          book.book_authors.create!(author: ::Books::Author.create!(name: "Brian W. Aldiss"), position: 1)
          ::Books::RebuildBookSurvey.create!(book: book, classification: :coherent, edition_count: 1, row_count: 2,
            title_agrees: false, authors_agree: false, wrong_book: true, surveyed_at: Time.current,
            groups: [{"edition_ids" => [1], "goodreads_book_ids" => [7], "titles" => ["The Hidden Harbor Mystery"],
                      "authors" => ["Franklin W. Dixon"], "year" => 1927, "volume" => nil, "row_count" => 2}])

          report = SurveyReport.call

          assert_match(/lump 1/, report)
          assert_match(/wrong book: 1/, report)
          assert_includes report, %(##{book.id} "Hothouse" by Brian W. Aldiss | export: "The Hidden Harbor Mystery" by Franklin W. Dixon (2 rows))
        end

        test "report shows evidence counts" do
          ::Books::RebuildEditionEvidence.create!(goodreads_book_id: 1, signature: "a", world_cat: :disagrees, ol_work_keys: [], checked_at: Time.current)

          report = SurveyReport.call

          # The war_and_peace fixture agrees and has a work; this row disagrees with none.
          assert_match(/evidence rows: 2; WorldCat agrees 1, disagrees 1, unclear 0, no record 0, no ISBN 0; with an Open Library work 1/, report)
        end
      end
    end
  end
end
