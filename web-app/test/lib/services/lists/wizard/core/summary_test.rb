# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class SummaryTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @admin = users(:admin_user)
            wizard_row(@list, position: 1, title: "Matched", listable: books_books(:war_and_peace), wizard: {bucket: "matched"})
            wizard_row(@list, position: 2, title: "Created", listable: books_books(:got),
              wizard: {bucket: "matched", import_result: "created", settled: true})
            wizard_row(@list, position: 3, title: "Admin linked", listable: books_books(:clash),
              wizard: {bucket: "matched", settled: true, settled_by_id: @admin.id})
            wizard_row(@list, position: 4, title: "Changed", listable: books_books(:cannery_row),
              wizard: {bucket: "matched", import_result: "linked_existing", reasons: ["changed_since_match"], settled: true})
            @flagged = wizard_row(@list, position: 5, title: "Flagged", wizard: {bucket: "flagged", reasons: ["unsure"]})
            wizard_row(@list, position: 6, title: "To create", wizard: {bucket: "create"})
            wizard_row(@list, position: 7, title: "Removed", wizard: {bucket: "removed", settled: true})
            @list.list_items.create!(listable: books_books(:of_mice_and_men), position: 8)
            # A row from before the wizard: no wizard key, no book.
            @list.list_items.create!(listable_type: "Books::Book", position: 9)
          end

          test "review counts buckets and settled rows, leaving out removed rows and rows from before the wizard" do
            assert_equal({"matched" => 4, "create" => 1, "flagged" => 1, "settled" => 3}, Summary.new(@list).review_counts)
            assert_equal 1, Summary.new(@list).flagged_count
          end

          test "unlinked count is rows with no book, leaving out removed rows" do
            assert_equal 3, Summary.new(@list).unlinked_count
          end

          test "done counts what the wizard did, and duplicate pairs raised by the rows' decisions" do
            decision = wizard_match(subject: @flagged, outcome: :unmatched).decision
            RowState.new(@flagged).merge("match_decision_id" => decision.id)
            @flagged.save!
            # A pair no fixture holds: an existing pair keeps the decision that first
            # raised it, so it would not count as new here.
            ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book",
              ids: [books_books(:war_and_peace).id, books_books(:crime_and_punishment).id],
              source: :ai, evidence: {}, match_decision: decision)

            assert_equal({"matched" => 1, "created" => 1, "admin_linked" => 1, "unlinked" => 3, "changed_since_match" => 1, "duplicate_pairs" => 1},
              Summary.new(@list).done_counts)
          end
        end
      end
    end
  end
end
