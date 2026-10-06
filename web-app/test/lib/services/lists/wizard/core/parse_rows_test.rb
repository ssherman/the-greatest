# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class ParseRowsTest < ActiveSupport::TestCase
          include ListWizardHelper

          setup do
            @list = wizard_list
            @adapter = ::Services::Lists::Wizard::Books::Adapter.new
          end

          def parsed(*rows)
            @adapter.stubs(:parse).returns(::Services::Lists::Wizard::Books::Adapter::Result.new(success?: true, data: rows, errors: []))
          end

          def row(title, authors = [], rank: nil, subtitle: nil, year: nil)
            {"rank" => rank, "title" => title, "subtitle" => subtitle, "authors" => authors, "year" => year}
          end

          test "each parsed book becomes a pending row at its rank, with its text in metadata" do
            parsed(row("Emma", ["Jane Austen"]), row("Sapiens", ["Yuval Noah Harari"], rank: 5, subtitle: "A Brief History", year: 2011))

            assert_equal 2, ParseRows.call(list: @list, adapter: @adapter)

            by_title = @list.list_items.reload.index_by { |item| item.metadata["title"] }
            emma = by_title.fetch("Emma")
            sapiens = by_title.fetch("Sapiens")
            assert_equal [1, 5], [emma.position, sapiens.position]
            assert_equal ["Sapiens", "A Brief History", ["Yuval Noah Harari"], 2011, "Books::Book"],
              [sapiens.metadata["title"], sapiens.metadata["subtitle"], sapiens.metadata["authors"], sapiens.metadata["year"], sapiens.listable_type]
            assert_equal({"bucket" => "pending", "reasons" => [], "settled" => false}, sapiens.metadata["wizard"])
            manager = @list.reload.wizard_manager
            assert_equal ["completed", 2], [manager.step_status("parse"), manager.step_metadata("parse")["total_items"]]
          end

          test "a re-parse replaces unsettled rows" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            parsed(row("Emma", ["Jane Austen"]))

            ParseRows.call(list: @list, adapter: @adapter)

            assert_not ::ListItem.exists?(old.id)
            assert_equal ["Emma"], @list.list_items.reload.map { |item| item.metadata["title"] }
          end

          test "re-parsing the same paste re-creates an unsettled row instead of dropping it" do
            old = wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"])
            parsed(row("Emma", ["Jane Austen"]))

            assert_equal 1, ParseRows.call(list: @list, adapter: @adapter)

            emmas = @list.list_items.reload.select { |item| item.metadata["title"] == "Emma" }
            assert_equal 1, emmas.size
            assert_not_equal old.id, emmas.first.id
          end

          test "a parse that finds no books fails and keeps the unsettled rows" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            parsed

            assert_nil ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            manager = @list.reload.wizard_manager
            assert_equal ["failed", "The parser found no books"], [manager.step_status("parse"), manager.step_error("parse")]
          end

          test "batch mode with blank simplified content fails and keeps the unsettled rows" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            @list.update_columns(simplified_content: " \n\n", wizard_state: {"batch_mode" => true})
            @adapter.expects(:parse).never

            assert_nil ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            assert_equal "failed", @list.reload.wizard_manager.step_status("parse")
          end

          test "a settled or removed row is kept, and a parsed row equal to it is not added again" do
            settled = wizard_row(@list, position: 1, title: "Emma", authors: ["Jane Austen"], wizard: {bucket: "matched", settled: true})
            removed = wizard_row(@list, position: 2, title: "Persuasion", authors: ["Jane Austen"], wizard: {bucket: "removed", settled: true})
            parsed(row(" emma ", ["JANE AUSTEN"]), row("Persuasion", ["Jane Austen"]), row("Mansfield Park", ["Jane Austen"]))

            assert_equal 1, ParseRows.call(list: @list, adapter: @adapter)

            titles = @list.list_items.reload.map { |item| item.metadata["title"] }
            assert_equal ["Emma", "Mansfield Park", "Persuasion"], titles.sort
            assert ::ListItem.exists?(settled.id)
            assert ::ListItem.exists?(removed.id)
          end

          test "a row from before the wizard is kept and not parsed again" do
            book = books_books(:war_and_peace)
            old = @list.list_items.create!(listable: book, position: 1)
            parsed(row("War and Peace", ["Leo Tolstoy"]), row("Emma", ["Jane Austen"]))

            ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            assert_equal 2, @list.list_items.reload.count
          end

          test "a failed re-parse deletes nothing and marks the step failed" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            @adapter.stubs(:parse).returns(::Services::Lists::Wizard::Books::Adapter::Result.new(success?: false, data: [], errors: ["rate limited"]))

            assert_nil ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            manager = @list.reload.wizard_manager
            assert_equal ["failed", "rate limited"], [manager.step_status("parse"), manager.step_error("parse")]
          end

          test "blank content fails without calling the parser" do
            @list.update_columns(raw_content: nil)
            @adapter.expects(:parse).never

            assert_nil ParseRows.call(list: @list, adapter: @adapter)
            assert_equal "failed", @list.reload.wizard_manager.step_status("parse")
          end

          test "batch mode parses 100 non-blank lines at a time and numbers rows sequentially, ignoring AI ranks" do
            lines = (1..150).map { |n| "Book #{n} by Author #{n}" }
            @list.update_columns(simplified_content: lines.each_slice(10).map { |slice| slice.join("\n") }.join("\n\n  \n"),
              wizard_state: {"batch_mode" => true})
            first = (1..100).map { |n| row("Book #{n}", ["Author #{n}"], rank: 1) }
            second = (101..150).map { |n| row("Book #{n}", ["Author #{n}"], rank: 1) }
            result = ->(rows) { ::Services::Lists::Wizard::Books::Adapter::Result.new(success?: true, data: rows, errors: []) }
            @adapter.expects(:parse).with(@list, content: lines.first(100).join("\n")).returns(result.call(first))
            @adapter.expects(:parse).with(@list, content: lines.last(50).join("\n")).returns(result.call(second))

            assert_equal 150, ParseRows.call(list: @list, adapter: @adapter)

            positions = @list.list_items.reload.to_h { |item| [item.metadata["title"], item.position] }
            assert_equal (1..150).to_a, positions.values.sort
            assert_equal [1, 100, 101, 150], positions.values_at("Book 1", "Book 100", "Book 101", "Book 150")
          end

          test "in batch mode a failed second batch deletes nothing and fails the step" do
            old = wizard_row(@list, position: 1, title: "Old Row")
            @list.update_columns(simplified_content: (1..150).map { |n| "Book #{n}" }.join("\n"), wizard_state: {"batch_mode" => true})
            ok = ::Services::Lists::Wizard::Books::Adapter::Result.new(success?: true, data: [row("Book 1")], errors: [])
            bad = ::Services::Lists::Wizard::Books::Adapter::Result.new(success?: false, data: [], errors: ["rate limited"])
            @adapter.stubs(:parse).returns(ok).then.returns(bad)

            assert_nil ParseRows.call(list: @list, adapter: @adapter)

            assert ::ListItem.exists?(old.id)
            assert_equal 1, @list.list_items.reload.count
            manager = @list.reload.wizard_manager
            assert_equal "failed", manager.step_status("parse")
            assert_match(/batch 2/, manager.step_error("parse"))
          end

          test "null bytes are stripped before they reach jsonb" do
            parsed(row("Em\u0000ma", ["Jane\u0000 Austen"]))

            ParseRows.call(list: @list, adapter: @adapter)

            item = @list.list_items.reload.first
            assert_equal ["Emma", ["Jane Austen"]], [item.metadata["title"], item.metadata["authors"]]
          end
        end
      end
    end
  end
end
