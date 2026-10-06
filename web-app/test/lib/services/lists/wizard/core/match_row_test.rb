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

          test "a finder error flags the row match_failed and the step can still finish" do
            finder = Object.new
            def finder.call(**) = raise(StandardError, "open library timed out")
            @adapter.stubs(:finder).returns(finder)

            MatchRow.call(list_item: @row, adapter: @adapter)

            state = RowState.new(@row.reload)
            assert_equal ["flagged", ["match_failed"], "open library timed out"], [state.bucket, state.reasons, state.error]
            assert_equal "completed", @list.reload.wizard_manager.step_status("match")
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
