# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class RowStateTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
          end

          test "a row with no wizard key is settled and not pending; a parsed row is pending and unsettled" do
            old = @list.list_items.create!(listable: books_books(:war_and_peace), position: 1)
            parsed = wizard_row(@list, position: 2, title: "Emma")

            assert RowState.new(old).settled?
            assert_not RowState.new(old).present?
            assert_not RowState.new(parsed).settled?
            assert RowState.new(parsed).pending?
          end

          test "merge writes into metadata under the wizard key without saving and keeps the rest" do
            row = wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"])

            RowState.new(row).merge(bucket: "flagged", reasons: ["unsure"])

            assert row.changed?
            assert_equal "Emma", row.metadata["title"]
            assert_equal ["flagged", ["unsure"], false], row.metadata["wizard"].values_at("bucket", "reasons", "settled")
            assert_equal "pending", row.reload.metadata.dig("wizard", "bucket")
          end

          test "settle records who and when" do
            row = wizard_row(@list, position: 1, title: "Emma")
            admin = users(:admin_user)

            freeze_time do
              state = RowState.new(row).settle(by: admin)
              assert state.settled?
              assert_equal [admin.id, Time.current.iso8601], [state.settled_by_id, state.data["settled_at"]]
            end
          end

          test "readers parse the stored values" do
            row = wizard_row(@list, position: 1, title: "Emma", wizard: {
              bucket: "create", ol_keys: ["OL1W"], ol_work_key: "OL1W", target_record_id: 7, match_decision_id: 9,
              decided_by: "ai", matched_at: "2026-10-06T10:00:00Z", import_result: "created", import_error: "boom", error: "bad"
            })
            state = RowState.new(row)

            assert_equal [["OL1W"], "OL1W", 7, 9, "ai", "created", "boom", "bad"],
              [state.ol_keys, state.ol_work_key, state.target_record_id, state.match_decision_id, state.decided_by,
                state.import_result, state.import_error, state.error]
            assert_equal Time.utc(2026, 10, 6, 10), state.matched_at
            assert state.decided?
            assert_not state.flagged?
            assert_not state.removed?
          end

          test "unsettled lists only rows the wizard may still change" do
            parsed = wizard_row(@list, position: 1, title: "Emma")
            wizard_row(@list, position: 2, title: "Persuasion", wizard: {settled: true})
            @list.list_items.create!(listable: books_books(:war_and_peace), position: 3)

            assert_equal [parsed.id], RowState.unsettled(@list).map(&:id)
          end

          test "holder_of finds another row holding the record, never the row asked about" do
            book = books_books(:war_and_peace)
            holder = wizard_row(@list, position: 1, title: "War and Peace", listable: book)
            other = wizard_row(@list, position: 2, title: "Emma")

            assert_equal holder, RowState.holder_of(@list, book, except: other)
            assert_nil RowState.holder_of(@list, book, except: holder)
            assert_nil RowState.holder_of(@list, books_books(:crime_and_punishment))
          end

          test "unlink clears the link and verification but keeps the listable type" do
            row = wizard_row(@list, position: 1, title: "War and Peace", listable: books_books(:war_and_peace), verified: true)

            RowState.unlink(row)

            assert_nil row.listable_id
            assert_equal ["Books::Book", false], [row.listable_type, row.verified]
          end

          test "flag! adds the reason once, flags the bucket, unlinks, and saves" do
            row = wizard_row(@list, position: 1, title: "War and Peace", listable: books_books(:war_and_peace), verified: true,
              wizard: {bucket: "matched", reasons: ["unsure"]})

            state = RowState.new(row).flag!("on_list_twice")
            RowState.new(row).flag!("on_list_twice")

            assert_kind_of RowState, state
            row.reload
            assert_equal ["flagged", ["unsure", "on_list_twice"]], row.metadata["wizard"].values_at("bucket", "reasons")
            assert_nil row.listable_id
            assert_not row.verified?
            assert_equal "Books::Book", row.listable_type
          end

          test "link! points the row at the record, verifies it, and saves" do
            row = wizard_row(@list, position: 1, title: "War and Peace")
            book = books_books(:war_and_peace)

            RowState.new(row).link!(book)

            row.reload
            assert_equal [book.id, true], [row.listable_id, row.verified]
          end

          test "label_for gives plain words for every reason the code writes and humanizes an unknown one" do
            %w[unsure not_found ai_only_pick on_list_twice match_failed import_failed changed_since_match].each do |reason|
              assert_not_equal reason.humanize, RowState.label_for(reason), "#{reason} has no plain label"
            end
            assert_equal "Something odd", RowState.label_for("something_odd")
          end
        end
      end
    end
  end
end
