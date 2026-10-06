# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class ReviewRowsTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @matched = wizard_row(@list, position: 1, title: "Matched", listable: books_books(:war_and_peace), wizard: {bucket: "matched", decided_by: "ai"})
            @flagged = wizard_row(@list, position: 2, title: "Flagged", wizard: {bucket: "flagged", reasons: ["unsure"], decided_by: "ai"})
            @create = wizard_row(@list, position: 3, title: "Create", wizard: {bucket: "create", decided_by: "rule"})
            @removed = wizard_row(@list, position: 4, title: "Removed", wizard: {bucket: "removed", settled: true})
          end

          def ids(filter) = ReviewRows.new(list: @list, filter: filter).rows.map { |row| row.item.id }

          test "the default view is flagged rows only" do
            assert_equal [@flagged.id], ids("flagged")
            assert_equal [@flagged.id], ids(nil)
            assert_equal "flagged", ReviewRows.new(list: @list, filter: "bogus").filter
          end

          test "the filters: all rows, rows to create, AI-decided rows; removed rows never show" do
            assert_equal [@matched.id, @flagged.id, @create.id], ids("all")
            assert_equal [@create.id], ids("create")
            assert_equal [@matched.id, @flagged.id], ids("ai")
          end

          test "each row carries its decision and its top candidates from the snapshot" do
            got = books_books(:got)
            candidates = [local_candidate(got, list_count: 4), ol_candidate("OL9W", title: "A Game of Thrones", creators: ["George R. R. Martin"], year: 1996)] +
              Array.new(6) { |i| ol_candidate("OL#{i}X") }
            decision = wizard_match(subject: @flagged, outcome: :unmatched, decided_by: :ai, candidates: candidates).decision
            RowState.new(@flagged).merge("match_decision_id" => decision.id)
            @flagged.save!

            row = ReviewRows.new(list: @list).rows.first

            assert_equal decision, row.decision
            assert_equal 6, row.candidates.size
            local, external = row.candidates
            assert_equal [true, got.id, got.title, 4], [local.local?, local.record_id, local.title, local.list_count]
            assert_equal [false, "OL9W", ["George R. R. Martin"], 1996], [external.local?, external.external_key, external.creators, external.year]
          end

          test "a row without a decision has no candidates" do
            assert_equal [], ReviewRows.new(list: @list).rows.first.candidates
          end

          test "rows come a page at a time, in list order, for every filter" do
            list = wizard_list
            (1..5).each { |n| wizard_row(list, position: n, title: "Row #{n}", wizard: {bucket: "flagged", decided_by: "ai"}) }

            %w[flagged all ai].each do |filter|
              first = ReviewRows.new(list: list, filter: filter, per_page: 2)
              assert_equal [5, 3, 1], [first.total, first.pages, first.page]
              assert_equal ["Row 1", "Row 2"], first.rows.map { |row| row.item.metadata["title"] }

              last = ReviewRows.new(list: list, filter: filter, per_page: 2, page: 3)
              assert_equal ["Row 5"], last.rows.map { |row| row.item.metadata["title"] }
            end
          end

          test "the page is clamped into range and defaults to 100 rows" do
            list = wizard_list
            (1..3).each { |n| wizard_row(list, position: n, title: "Row #{n}", wizard: {bucket: "flagged"}) }

            assert_equal 100, ReviewRows.new(list: list).per_page
            assert_equal 2, ReviewRows.new(list: list, per_page: 2, page: 99).page
            assert_equal 1, ReviewRows.new(list: list, per_page: 2, page: "junk").page
            assert_equal 1, ReviewRows.new(list: list, per_page: 2, page: 0).page
            assert_equal [1, 0], [ReviewRows.new(list: wizard_list).pages, ReviewRows.new(list: wizard_list).total]
          end
        end
      end
    end
  end
end
