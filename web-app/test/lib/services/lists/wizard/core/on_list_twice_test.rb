# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class OnListTwiceTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @book = books_books(:war_and_peace)
          end

          test "two rows landing on the same local book are both flagged and the linked one is unlinked" do
            linked = wizard_row(@list, position: 1, title: "War and Peace", listable: @book, verified: true,
              wizard: {bucket: "matched", target_record_id: @book.id})
            blocked = wizard_row(@list, position: 2, title: "War & Peace",
              wizard: {bucket: "flagged", reasons: ["on_list_twice"], target_record_id: @book.id})

            assert_equal 2, OnListTwice.call(list: @list)

            linked.reload
            assert_equal ["flagged", ["on_list_twice"]], linked.metadata["wizard"].values_at("bucket", "reasons")
            assert_nil linked.listable_id
            assert_not linked.verified?
            assert_equal ["on_list_twice"], blocked.reload.metadata.dig("wizard", "reasons")
          end

          test "two create rows for the same Open Library work are both flagged" do
            a = wizard_row(@list, position: 1, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            b = wizard_row(@list, position: 2, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})

            OnListTwice.call(list: @list)

            assert_equal ["flagged", "flagged"], [a, b].map { |row| row.reload.metadata.dig("wizard", "bucket") }
          end

          test "a settled row in a clash is left alone and the unsettled one is flagged" do
            settled = wizard_row(@list, position: 1, title: "War and Peace", listable: @book, verified: true,
              wizard: {bucket: "matched", target_record_id: @book.id, settled: true})
            unsettled = wizard_row(@list, position: 2, title: "War and Peace",
              wizard: {bucket: "flagged", reasons: ["on_list_twice"], target_record_id: @book.id})

            assert_equal 1, OnListTwice.call(list: @list)
            assert_equal [@book.id, "matched"], [settled.reload.listable_id, settled.metadata.dig("wizard", "bucket")]
            assert_equal "flagged", unsettled.reload.metadata.dig("wizard", "bucket")
          end

          test "rows on different books or works, and removed rows, are not a clash" do
            wizard_row(@list, position: 1, title: "War and Peace", listable: @book, wizard: {bucket: "matched", target_record_id: @book.id})
            crime = books_books(:crime_and_punishment)
            other = wizard_row(@list, position: 2, title: "Crime and Punishment", listable: crime, wizard: {bucket: "matched", target_record_id: crime.id})
            wizard_row(@list, position: 3, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            wizard_row(@list, position: 4, title: "Dune again", wizard: {bucket: "removed", settled: true, ol_work_key: "OL5W"})
            wizard_row(@list, position: 5, title: "Emma", wizard: {bucket: "create", ol_work_key: "OL6W"})

            assert_equal 0, OnListTwice.call(list: @list)
            assert_equal "matched", other.reload.metadata.dig("wizard", "bucket")
          end

          test "running the pass twice changes nothing more" do
            wizard_row(@list, position: 1, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            wizard_row(@list, position: 2, title: "Dune", wizard: {bucket: "create", ol_work_key: "OL5W"})
            OnListTwice.call(list: @list)
            first = @list.list_items.reload.map { |row| row.metadata["wizard"] }

            OnListTwice.call(list: @list)

            assert_equal first, @list.list_items.reload.map { |row| row.metadata["wizard"] }
          end
        end
      end
    end
  end
end
