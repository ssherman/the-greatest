# frozen_string_literal: true

require "test_helper"

module CsvExports
  class SavedSearchTest < ActiveSupport::TestCase
    setup do
      @search = saved_searches(:books_public)
      @books = [books_books(:war_and_peace), books_books(:crime_and_punishment)]
    end

    def stub_pages(pages)
      ::Search::Books::Search::BookAdvanced.stubs(:call).returns(
        *pages.map { |ids| {ids: ids, total: pages.flatten.size, total_relation: "eq"} }
      )
    end

    def export(limit:)
      io = StringIO.new
      rows = SavedSearch.call(search: @search, limit: limit, io: io)
      [rows, CSV.parse(io.string.delete_prefix(Writer::BOM))]
    end

    test "writes the books columns for every result, in search order" do
      stub_pages([@books.map(&:id).reverse])

      rows, parsed = export(limit: nil)

      assert_equal 2, rows
      assert_equal Books::RankedBookRow::HEADERS, parsed.first
      assert_equal ["Crime and Punishment", "War and Peace"], parsed.drop(1).map { |row| row[3] }
    end

    # `opts` rather than keyword block params: Mocha hands the call's keyword
    # arguments to a matching block in a version-dependent shape, and a plain
    # second positional swallows either one.
    test "the limit caps rows and sizes the page to the limit" do
      ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, opts|
        opts[:page] == 1 && opts[:per_page] == 1
      }.returns({ids: [@books.first.id], total: 2, total_relation: "eq"}).once

      rows, _parsed = export(limit: 1)

      assert_equal 1, rows
    end

    test "a member's export asks for full pages" do
      ::Search::Books::Search::BookAdvanced.expects(:call).with { |_criteria, opts|
        opts[:per_page] == SavedSearch::PER_PAGE
      }.returns({ids: [], total: 0, total_relation: "eq"}).once

      export(limit: nil)
    end

    test "stops after a short page without asking for another" do
      ::Search::Books::Search::BookAdvanced.expects(:call).once
        .returns({ids: [@books.first.id], total: 1, total_relation: "eq"})

      rows = SavedSearch.call(search: @search, limit: nil, io: StringIO.new)

      assert_equal 1, rows
    end

    test "never asks past the OpenSearch window" do
      assert_equal 10, SavedSearch.max_page(per_page: 1000)
    end

    test "rank and score come from the hydrated book" do
      RankedItem.where(item: @books.first).delete_all
      RankedItem.create!(item: @books.first, ranking_configuration: ::Books::RankingConfiguration.default_primary,
        rank: 3, score: 12.25)
      stub_pages([[@books.first.id]])

      _rows, parsed = export(limit: nil)

      assert_equal ["3", "12.25"], parsed[1][0..1]
    end
  end
end
