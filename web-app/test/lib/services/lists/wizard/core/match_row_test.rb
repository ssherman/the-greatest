# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class MatchRowTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @list.wizard_manager.write_step!(step: "match", status: "running")
            @adapter = ::Services::Lists::Wizard::Books::Adapter.new
            @book = books_books(:war_and_peace)
            @row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"])
          end

          def answer(**attributes)
            finder = ListWizardHelper::FakeFinder.new(->(row) { wizard_match(subject: row, **attributes) })
            @adapter.stubs(:finder).returns(finder)
            finder
          end

          test "a confident match links the row, verifies it and records the decision" do
            finder = answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter)

            @row.reload
            state = RowState.new(@row)
            assert_equal [@book.id, true, "matched", @book.id, "identifier"],
              [@row.listable_id, @row.verified, state.bucket, state.target_record_id, state.decided_by]
            assert_equal ::MatchDecision.where(subject: @row).last.id, state.match_decision_id
            assert state.matched_at.present?
            assert_equal @row, finder.calls.first[:subject]
            assert_equal "War and Peace", finder.calls.first[:query].title
          end

          test "an AI match at high confidence passes through, remembered as AI-decided" do
            answer(outcome: :matched, record: @book, confidence: :high, decided_by: :ai, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_equal [@book.id, "matched", "ai"], [@row.reload.listable_id, RowState.new(@row).bucket, RowState.new(@row).decided_by]
          end

          test "an unsure match is flagged and left unlinked" do
            answer(outcome: :matched, record: @book, confidence: :medium, decided_by: :ai, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["unsure"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "a rule-5 create saves the work and the keys the re-check needs" do
            work = ol_candidate("OL9W")
            answer(outcome: :unmatched, confidence: :high, decided_by: :rule, external: work, candidates: [work])
            @adapter.stubs(:recheck_keys).returns(%w[OL9W OL8W])

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_equal ["create", "OL9W", %w[OL9W OL8W]], [state.bucket, state.ol_work_key, state.ol_keys]
          end

          test "a match on a book a settled row holds is flagged on_list_twice, not linked, and the holder stays linked" do
            holder = wizard_row(@list, position: 2, title: "War and Peace (again)", listable: @book, wizard: {bucket: "matched", settled: true})
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_nil @row.listable_id
            assert_equal ["flagged", ["on_list_twice"], @book.id], [state.bucket, state.reasons, state.target_record_id]
            assert_equal @book.id, holder.reload.listable_id
          end

          test "a uniqueness clash at save time flags the row instead of crashing" do
            wizard_row(@list, position: 2, title: "War and Peace (again)", listable: @book, wizard: {bucket: "matched", settled: true})
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            # The other row linked the book after this job looked (two jobs at once).
            RowState.stubs(:holder_of).returns(nil)

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["on_list_twice"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "the unique index firing (two jobs at once, validation bypassed) also flags the row" do
            wizard_row(@list, position: 2, title: "War and Peace (again)", listable: @book, wizard: {bucket: "matched", settled: true})
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            RowState.stubs(:holder_of).returns(nil)
            # Skip the uniqueness validation so the save reaches the database index.
            ::ListItem.any_instance.stubs(:valid?).returns(true)

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["on_list_twice"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "two unsettled rows on one book both end up flagged on_list_twice once Match completes" do
            other = wizard_row(@list, position: 2, title: "War and Peace (again)")
            @adapter.stubs(:finder).returns(ListWizardHelper::FakeFinder.new(->(row) {
              wizard_match(subject: row, outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            }))

            MatchRow.call(list_item: @row, adapter: @adapter)
            assert_equal @book.id, @row.reload.listable_id # the first lands; the step is not done yet
            MatchRow.call(list_item: other, adapter: @adapter)

            [@row, other].each do |row|
              row.reload
              assert_nil row.listable_id
              assert_equal ["flagged", ["on_list_twice"]], [RowState.new(row).bucket, RowState.new(row).reasons]
            end
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "a row the admin settled while its job was in flight is left alone, and progress still runs" do
            finder = ListWizardHelper::FakeFinder.new(->(row) {
              fresh = ::ListItem.find(row.id)
              RowState.new(fresh).merge("bucket" => "removed", "reasons" => []).settle(by: users(:admin_user))
              fresh.save!
              wizard_match(subject: row, outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            })
            @adapter.stubs(:finder).returns(finder)

            MatchRow.call(list_item: @row, adapter: @adapter)

            @row.reload
            assert_nil @row.listable_id
            assert_equal ["removed", true], [RowState.new(@row).bucket, RowState.new(@row).settled?]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          # Jitter spreads rows that failed together: delay..2*delay seconds out.
          def assert_retry_delay_within(delay, job)
            wait = job["at"] - Time.now.to_f
            assert_operator wait, :>=, delay - 2
            assert_operator wait, :<=, 2 * delay + 2
          end

          def failed_source_answer(**attributes)
            answer(outcome: :matched, record: @book, confidence: :medium, decided_by: :rule, candidates: [local_candidate(@book)],
              sources_failed: ["open_library"], **attributes)
          end

          test "a match with a failed source on the first attempt leaves the row pending and schedules attempt 2" do
            failed_source_answer
            decision_count = ::MatchDecision.count

            Sidekiq::Testing.fake! do
              ::Lists::Wizard::MatchRowJob.jobs.clear
              MatchRow.call(list_item: @row, adapter: @adapter, single_row: true)

              job = ::Lists::Wizard::MatchRowJob.jobs.last
              assert_equal [@row.id, true, 2], job["args"]
              assert_retry_delay_within MatchRow::RETRY_DELAYS.first, job
            end

            state = RowState.new(@row.reload)
            assert_equal "pending", state.bucket
            assert_nil @row.listable_id
            assert_nil state.match_decision_id
            assert_nil state.decided_by
            assert_equal decision_count + 1, ::MatchDecision.count # the finder wrote one for the attempt
          end

          test "the retry delay is jittered by up to the delay itself" do
            failed_source_answer
            MatchRow.any_instance.stubs(:rand).with(0..20).returns(20)

            Sidekiq::Testing.fake! do
              ::Lists::Wizard::MatchRowJob.jobs.clear
              MatchRow.call(list_item: @row, adapter: @adapter)
              assert_in_delta 40, ::Lists::Wizard::MatchRowJob.jobs.last["at"] - Time.now.to_f, 2
            end
          end

          test "attempt 2 failing again schedules attempt 3 after the longer delay" do
            failed_source_answer

            Sidekiq::Testing.fake! do
              ::Lists::Wizard::MatchRowJob.jobs.clear
              MatchRow.call(list_item: @row, adapter: @adapter, attempt: 2)

              job = ::Lists::Wizard::MatchRowJob.jobs.last
              assert_equal [@row.id, false, 3], job["args"]
              assert_retry_delay_within MatchRow::RETRY_DELAYS.last, job
            end
          end

          test "the final attempt applies the capped result, flagged unsure, and names the failed source" do
            failed_source_answer

            Sidekiq::Testing.fake! do
              ::Lists::Wizard::MatchRowJob.jobs.clear
              MatchRow.call(list_item: @row, adapter: @adapter, attempt: MatchRow::MAX_ATTEMPTS)
              assert_empty ::Lists::Wizard::MatchRowJob.jobs
            end

            state = RowState.new(@row.reload)
            assert_nil @row.listable_id
            assert_equal ["flagged", ["unsure"]], [state.bucket, state.reasons]
            assert_includes state.error, "open_library"
            assert state.match_decision_id.present?
          end

          test "serial: a failed source on any attempt leaves the row pending, queues nothing and answers :retry" do
            failed_source_answer

            Sidekiq::Testing.fake! do
              ::Lists::Wizard::MatchRowJob.jobs.clear
              row = MatchRow.new(@row, @adapter, false, MatchRow::MAX_ATTEMPTS + 3, nil, serial: true)
              assert_equal :retry, row.call
              assert_equal ["open_library"], row.failed_sources
              assert_empty ::Lists::Wizard::MatchRowJob.jobs
            end

            assert_equal ["pending", nil], [RowState.new(@row.reload).bucket, @row.listable_id]
          end

          test "serial: an answered row is applied and answers :done" do
            answer(outcome: :matched, record: @book, confidence: :high, decided_by: :rule, candidates: [local_candidate(@book)])

            assert_equal :done, MatchRow.call(list_item: @row, adapter: @adapter, serial: true)

            assert_equal [@book.id, "matched"], [@row.reload.listable_id, RowState.new(@row).bucket]
          end

          test "a successful retry applies normally" do
            answer(outcome: :matched, record: @book, confidence: :high, decided_by: :rule, candidates: [local_candidate(@book)])

            MatchRow.call(list_item: @row, adapter: @adapter, attempt: 2)

            state = RowState.new(@row.reload)
            assert_equal [@book.id, "matched", nil], [@row.listable_id, state.bucket, state.error]
          end

          test "a retry for a row the admin settled meanwhile does nothing" do
            RowState.new(@row).merge("bucket" => "removed", "reasons" => []).settle(by: users(:admin_user))
            @row.save!
            failed_source_answer

            Sidekiq::Testing.fake! do
              ::Lists::Wizard::MatchRowJob.jobs.clear
              MatchRow.call(list_item: @row, adapter: @adapter)
              assert_empty ::Lists::Wizard::MatchRowJob.jobs
            end

            assert_equal ["removed", true], [RowState.new(@row.reload).bucket, RowState.new(@row).settled?]
          end

          test "the step does not complete while a row awaits a source retry" do
            failed_source_answer

            Sidekiq::Testing.fake! do
              MatchRow.call(list_item: @row, adapter: @adapter)
            end

            assert_equal "running", @list.reload.wizard_manager.step_status("match")
          end

          test "scheduling a retry still writes a progress heartbeat for a full Match" do
            wizard_row(@list, position: 2, title: "Emma", wizard: {bucket: "matched"})
            failed_source_answer

            Sidekiq::Testing.fake! { MatchRow.call(list_item: @row, adapter: @adapter) }

            manager = @list.reload.wizard_manager
            assert_equal ["running", 1, 2], [manager.step_status("match"), manager.step_metadata("match")["processed_items"],
              manager.step_metadata("match")["total_items"]]
          end

          test "scheduling a single-row retry never flips a completed step back to running" do
            @list.wizard_manager.write_step!(step: "match", status: "completed", progress: 100)
            failed_source_answer

            Sidekiq::Testing.fake! { MatchRow.call(list_item: @row, adapter: @adapter, single_row: true) }

            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "a finder error flags the row match_failed and the step can still finish" do
            finder = Object.new
            def finder.call(**) = raise(StandardError, "open library timed out")
            @adapter.stubs(:finder).returns(finder)

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_equal ["flagged", ["match_failed"], "open library timed out"], [state.bucket, state.reasons, state.error]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
          end

          test "a failed re-match of a decided row clears the earlier run's decision" do
            RowState.new(@row).merge("bucket" => "pending", "match_decision_id" => 99, "decided_by" => "ai", "confidence" => "high",
              "ol_keys" => ["OL1W"], "ol_work_key" => "OL1W", "target_record_id" => @book.id)
            @row.save!
            finder = Object.new
            def finder.call(**) = raise(StandardError, "open library timed out")
            @adapter.stubs(:finder).returns(finder)

            MatchRow.call(list_item: @row, adapter: @adapter)

            data = RowState.new(@row.reload).data
            assert_equal [nil] * 6, data.values_at("match_decision_id", "decided_by", "confidence", "ol_work_key", "target_record_id", "import_error")
            assert_equal [], data["ol_keys"]
          end

          test "a failure while building the decision (recheck_keys raising) leaves the row flagged and unlinked" do
            answer(outcome: :matched, record: @book, confidence: :certain, decided_by: :identifier)
            @adapter.stubs(:recheck_keys).raises(StandardError, "boom")

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_equal ["flagged", ["match_failed"]], [RowState.new(@row).bucket, RowState.new(@row).reasons]
          end

          test "a re-match replaces an earlier link" do
            @row.update!(listable: books_books(:crime_and_punishment), verified: true)
            answer(outcome: :unmatched, confidence: :high, decided_by: :rule, candidates: [])

            MatchRow.call(list_item: @row, adapter: @adapter)

            assert_nil @row.reload.listable_id
            assert_not @row.verified?
          end
        end
      end
    end
  end
end
