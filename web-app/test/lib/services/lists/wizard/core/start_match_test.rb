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

          def no_sleep = ->(_seconds) { flunk "no wait expected" }

          def not_found(subject, sources_failed: [])
            wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [],
              sources_failed: sources_failed)
          end

          def use_finder(answer)
            finder = ListWizardHelper::FakeFinder.new(answer)
            adapter = ::Services::Lists::Wizard::Books::Adapter.new
            adapter.stubs(:finder).returns(finder)
            Adapters.stubs(:for).returns(adapter)
            finder
          end

          test "marks every replaceable row pending, then matches each one in this job, queueing no row jobs" do
            matched = wizard_row(@list, position: 1, title: "War and Peace",
              wizard: {bucket: "matched", target_record_id: books_books(:war_and_peace).id})
            flagged = wizard_row(@list, position: 2, title: "Emma", wizard: {bucket: "flagged", reasons: ["unsure"]})
            finder = use_finder(->(subject) { not_found(subject) })
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).never
            ::Lists::Wizard::MatchRowJob.expects(:perform_in).never

            assert_equal 2, StartMatch.call(list: @list, sleeper: no_sleep)

            assert_nil matched.reload.listable_id
            assert_equal [matched.id, flagged.id], finder.calls.map { |call| call[:subject].id }
            assert_equal [["flagged", ["not_found"]], ["flagged", ["not_found"]]], [matched, flagged.reload].map { |row| RowState.new(row).data.values_at("bucket", "reasons") }
            assert_equal ["completed", 2], [@list.reload.wizard_manager.step_status("match"), @list.wizard_manager.step_metadata("match")["total_items"]]
          end

          test "rows are matched one at a time in list order" do
            second = wizard_row(@list, position: 2, title: "Emma")
            first = wizard_row(@list, position: 1, title: "Persuasion")
            finder = use_finder(->(subject) { not_found(subject) })

            StartMatch.call(list: @list, sleeper: no_sleep)

            assert_equal [first.id, second.id], finder.calls.map { |call| call[:subject].id }
          end

          test "a row whose source failed waits and is matched again before the next row starts" do
            first = wizard_row(@list, position: 1, title: "Persuasion")
            second = wizard_row(@list, position: 2, title: "Emma")
            failures = 1
            finder = use_finder(->(subject) {
              if subject.id == first.id && failures.positive?
                failures -= 1
                not_found(subject, sources_failed: [:open_library])
              else
                not_found(subject)
              end
            })
            waits = []
            ::Lists::Wizard::MatchRowJob.expects(:perform_in).never

            StartMatch.call(list: @list, sleeper: ->(seconds) { waits << seconds })

            assert_equal [first.id, first.id, second.id], finder.calls.map { |call| call[:subject].id }
            assert_equal [StartMatch::SOURCE_RETRY_DELAYS.first], waits
            assert_equal [["flagged", nil], ["flagged", nil]], [first, second].map { |row| RowState.new(row.reload).data.values_at("bucket", "error") }
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "a row Open Library never answers pauses the Match: the step fails and no row is flagged for it" do
            first = wizard_row(@list, position: 1, title: "Persuasion")
            second = wizard_row(@list, position: 2, title: "Emma")
            finder = use_finder(->(subject) { not_found(subject, sources_failed: [:open_library]) })
            waits = []

            StartMatch.call(list: @list, sleeper: ->(seconds) { waits << seconds })

            assert_equal StartMatch::SOURCE_RETRY_DELAYS, waits
            assert_equal [first.id] * (StartMatch::SOURCE_RETRY_DELAYS.size + 1), finder.calls.map { |call| call[:subject].id }
            assert_equal %w[pending pending], [first, second].map { |row| RowState.new(row.reload).bucket }
            manager = @list.reload.wizard_manager
            assert_equal "failed", manager.step_status("match")
            assert_match(/open_library/, manager.step_error("match"))
          end

          test "a run replaced while it works stops before its next row" do
            first = wizard_row(@list, position: 1, title: "Persuasion")
            wizard_row(@list, position: 2, title: "Emma")
            @list.wizard_manager.write_step!(step: "match", status: "running", metadata: {"run_id" => "run-1"})
            finder = use_finder(->(subject) {
              @list.wizard_manager.write_step!(step: "match", status: "running", metadata: {"run_id" => "run-2"})
              not_found(subject)
            })

            StartMatch.call(list: @list, run_id: "run-1", sleeper: no_sleep)

            assert_equal [first.id], finder.calls.map { |call| call[:subject].id }
          end

          test "the same run started again (requeued at a deploy) keeps the rows it already decided" do
            done = wizard_row(@list, position: 1, title: "Persuasion")
            left = wizard_row(@list, position: 2, title: "Emma")
            @list.wizard_manager.write_step!(step: "match", status: "running", metadata: {"run_id" => "run-1"})
            first_pass = use_finder(->(subject) {
              raise Interrupt if subject.id == left.id

              not_found(subject)
            })
            assert_raises(Interrupt) { StartMatch.call(list: @list, run_id: "run-1", sleeper: no_sleep) }
            assert_equal [done.id, left.id], first_pass.calls.map { |call| call[:subject].id }

            second_pass = use_finder(->(subject) { not_found(subject) })
            StartMatch.call(list: @list, run_id: "run-1", sleeper: no_sleep)

            assert_equal [left.id], second_pass.calls.map { |call| call[:subject].id }
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
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

          test "a row linked to a book is kept and not re-queued or unlinked" do
            book = books_books(:war_and_peace)
            linked = wizard_row(@list, position: 1, title: "War and Peace", listable: book, verified: true,
              wizard: {bucket: "matched", target_record_id: book.id})
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).never

            assert_equal 0, StartMatch.call(list: @list)

            linked.reload
            assert_equal [book.id, true, "matched"], [linked.listable_id, linked.verified, RowState.new(linked).bucket]
          end

          test "a settled row stuck pending is re-queued, and inline the Match completes with it decided" do
            row = wizard_row(@list, position: 1, title: "Emma", wizard: {bucket: "pending", settled: true})
            adapter = ::Services::Lists::Wizard::Books::Adapter.new
            adapter.stubs(:finder).returns(ListWizardHelper::FakeFinder.new(->(subject) {
              wizard_match(subject: subject, outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])
            }))
            Adapters.stubs(:for).returns(adapter)

            assert_equal 1, StartMatch.call(list: @list)

            assert_equal "flagged", RowState.new(row.reload).bucket
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end
        end
      end
    end
  end
end
