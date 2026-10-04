# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class DryRunTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @bytes = file_fixture("goodreads/small_export.csv").binread
        end

        test "reports each decision" do
          report = DryRun.call(bytes: @bytes, user: users(:regular_user)).data[:report]

          assert_match "Goodreads dry run: 3 rows, 2 editions. Nothing was saved.", report
          assert_match "matched 1 | created 1 | flagged 0 | failed rows 1 | AI calls 0", report
          assert_match %(row 1: gr 12345678 "War and Peace" by Leo Tolstoy -> matched Books::Book##{books_books(:war_and_peace).id}), report
          assert_match %r{row 2: gr 90000001 "The Quiet Year" by Anna Brenner -> created provisional Books::Book#\d+ "The Quiet Year" \(unverified\)}, report
          assert_match "row 3: failed: no Goodreads book id", report
        end

        test "saves nothing" do
          counted = ["::Books::Book.count", "::Books::Author.count", "::Books::GoodreadsImport.count",
            "::Books::GoodreadsEdition.count", "::Books::GoodreadsImportRow.count", "::MatchDecision.count", "::Identifier.count"]

          assert_no_difference(counted) { DryRun.call(bytes: @bytes, user: users(:regular_user)) }
        end

        test "a file that is not an export is refused with the reason" do
          result = DryRun.call(bytes: "Title,Author\nX,Y\n", user: users(:regular_user))

          assert_not result.success?
          assert_match "missing Goodreads export headers", result.errors.sole
        end

        test "a user with an import in progress can still dry-run" do
          ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)

          assert DryRun.call(bytes: @bytes, user: users(:regular_user)).success?
        end
      end
    end
  end
end
