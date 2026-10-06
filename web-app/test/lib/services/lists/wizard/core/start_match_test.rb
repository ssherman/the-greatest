# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class StartMatchTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
          end

          test "queues one job per unsettled row after marking each pending and unlinked" do
            matched = wizard_row(@list, position: 1, title: "War and Peace", listable: books_books(:war_and_peace), verified: true,
              wizard: {bucket: "matched", target_record_id: books_books(:war_and_peace).id})
            flagged = wizard_row(@list, position: 2, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(matched.id)
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(flagged.id)

            assert_equal 2, StartMatch.call(list: @list)

            matched.reload
            assert_nil matched.listable_id
            assert_equal [["pending", []], ["pending", []]], [matched, flagged.reload].map { |row| RowState.new(row).data.values_at("bucket", "reasons") }
            assert_equal ["running", 2], [@list.reload.wizard_manager.step_status("match"), @list.wizard_manager.step_metadata("match")["total_items"]]
          end

          test "settled rows and rows from before the wizard are never queued" do
            settled = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "matched", settled: true})
            old = @list.list_items.create!(listable: books_books(:got), position: 2)
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).never

            assert_equal 0, StartMatch.call(list: @list)

            assert_equal "matched", RowState.new(settled.reload).bucket
            assert_equal books_books(:got).id, old.reload.listable_id
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "inline, the whole run ends with the step completed" do
            row = wizard_row(@list, position: 1, title: "Emma")
            adapter = ::Services::Lists::Wizard::Books::Adapter.new
            adapter.stubs(:finder).returns(ListWizardHelper::FakeFinder.new(->(subject) {
              wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])
            }))
            Adapters.stubs(:for).returns(adapter)

            StartMatch.call(list: @list)

            assert_equal ["flagged", ["not_found"]], [RowState.new(row.reload).bucket, RowState.new(row).reasons]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end
        end
      end
    end
  end
end
