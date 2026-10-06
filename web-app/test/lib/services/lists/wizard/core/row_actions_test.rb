# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class RowActionsTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @admin = users(:admin_user)
            @book = books_books(:war_and_peace)
            @other = books_books(:got)
            @row = wizard_row(@list, position: 1, title: "War and Peace", authors: ["Leo Tolstoy"], wizard: {bucket: "flagged", reasons: ["unsure"]})
          end

          def with_decision(**attributes)
            decision = wizard_match(subject: @row, **attributes).decision
            RowState.new(@row).merge("match_decision_id" => decision.id)
            @row.save!
            decision
          end

          def actions = RowActions.new(list_item: @row, user: @admin)

          test "link links the book, settles the row and confirms a decision that named the same book" do
            decision = with_decision(outcome: :matched, record: @book, confidence: :medium, candidates: [local_candidate(@book)])

            result = actions.link(@book)

            assert result.success?
            @row.reload
            state = RowState.new(@row)
            assert_equal [@book.id, true, "matched", [], true, @admin.id], [@row.listable_id, @row.verified, state.bucket, state.reasons, state.settled?, state.settled_by_id]
            decision.reload
            assert_equal [true, @admin.id], [decision.verdict_confirmed?, decision.reviewed_by_id]
            assert decision.reviewed_at.present?
          end

          test "link to a different book than the finder named rejects its decision" do
            decision = with_decision(outcome: :matched, record: @other, confidence: :medium)

            actions.link(@book)

            assert decision.reload.verdict_rejected?
          end

          test "link refuses a book another row holds, changes nothing and reviews nothing" do
            wizard_row(@list, position: 2, title: "War and Peace", listable: @book, wizard: {bucket: "matched"})
            decision = with_decision(outcome: :matched, record: @book, confidence: :medium)

            result = actions.link(@book)

            assert_not result.success?
            assert result.errors.first.present?
            assert_nil @row.reload.listable_id
            assert_equal "flagged", RowState.new(@row).bucket
            assert_nil decision.reload.reviewed_at
          end

          test "link refuses a missing record" do
            assert_not actions.link(nil).success?
          end

          test "a row with no decision is acted on without recording one" do
            assert actions.link(@book).success?
            assert_equal @book.id, @row.reload.listable_id
          end

          test "create_from_external moves the row to create with that work" do
            work = ol_candidate("OL9W")
            with_decision(outcome: :unmatched, decided_by: :ai, external: work, candidates: [local_candidate(@other), work])

            result = actions.create_from_external("OL9W")

            assert result.success?
            state = RowState.new(@row.reload)
            assert_equal ["create", "OL9W", true], [state.bucket, state.ol_work_key, state.settled?]
            assert_includes state.ol_keys, "OL9W"
          end

          test "create_from_external refuses a work that is not a candidate, and one a book we hold carries" do
            held = ::DataImporters::Candidate.new(record: @other, external_key: "OL7W", external_source: :open_library, sources: [:open_library])
            with_decision(outcome: :unmatched, decided_by: :ai, candidates: [held])

            assert_not actions.create_from_external("OL1W").success?
            assert_not actions.create_from_external("OL7W").success?
            assert_equal "flagged", RowState.new(@row.reload).bucket
          end

          test "create_from_text moves the row to create, unlinks it and clears the Match-time work keys" do
            @row.update!(listable: @book, verified: true)
            RowState.new(@row).merge("ol_work_key" => "OL5W", "ol_keys" => ["OL5W", "OL6W"])
            @row.save!

            assert actions.create_from_text.success?

            @row.reload
            state = RowState.new(@row)
            assert_nil @row.listable_id
            assert_not @row.verified?
            assert_equal ["create", nil, [], true], [state.bucket, state.ol_work_key, state.ol_keys, state.settled?]
          end

          test "edit_and_rematch saves the new text, settles the row, queues a single-row re-match and rejects the old decision" do
            decision = with_decision(outcome: :unmatched, decided_by: :rule, candidates: [])
            ::Lists::Wizard::MatchRowJob.expects(:perform_async).with(@row.id, true)

            result = actions.edit_and_rematch(title: "War and Peace", subtitle: "A Novel", authors: "Leo Tolstoy\nLouise Maude", year: "1869")

            assert result.success?
            @row.reload
            assert_equal ["A Novel", ["Leo Tolstoy", "Louise Maude"], 1869], @row.metadata.values_at("subtitle", "authors", "year")
            assert_equal ["pending", true], [RowState.new(@row).bucket, RowState.new(@row).settled?]
            assert decision.reload.verdict_rejected?
          end

          test "edit cleans the year and the author lines, and refuses a blank title" do
            ::Lists::Wizard::MatchRowJob.stubs(:perform_async)

            actions.edit_and_rematch(title: " Emma ", subtitle: "", authors: "\n Jane Austen \n\n", year: " 1815 ")
            assert_equal ["Emma", nil, ["Jane Austen"], 1815], @row.reload.metadata.values_at("title", "subtitle", "authors", "year")

            actions.edit_and_rematch(title: "Emma", subtitle: nil, authors: "Jane Austen", year: "early 1800s")
            assert_nil @row.reload.metadata["year"]

            result = actions.edit_and_rematch(title: "  ", subtitle: nil, authors: "Jane Austen", year: nil)
            assert_not result.success?
            assert_equal "Emma", @row.reload.metadata["title"]
          end

          test "remove hides the row as removed, settled and unlinked, and it no longer holds a book" do
            @row.update!(listable: @book, verified: true)

            assert actions.remove.success?

            @row.reload
            assert_nil @row.listable_id
            assert_not @row.verified?
            assert_equal ["removed", true], [RowState.new(@row).bucket, RowState.new(@row).settled?]
            assert_nil RowState.holder_of(@list, @book)
          end
        end
      end
    end
  end
end
