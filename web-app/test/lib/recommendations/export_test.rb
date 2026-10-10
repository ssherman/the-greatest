# frozen_string_literal: true

require "test_helper"
require "zlib"
require "csv"

module Recommendations
  class ExportTest < ActiveSupport::TestCase
    def setup
      @user = users(:regular_user)
    end

    def rows_in(store, key)
      CSV.parse(Zlib.gunzip(store.get(key)), headers: true).map { |r| [r["user_id"].to_i, r["item_id"].to_i] }
    end

    test "writes a gzipped, sorted csv with a header and moves the pointer" do
      Dir.mktmpdir do |dir|
        store = Store::Local.new(dir)
        result = Export.call(domain: :books, store: store, name: "2026-10-09")
        assert result.success?, result.errors.inspect
        assert_equal "recommendations/books/interactions/2026-10-09.csv.gz", result.data[:key]
        rows = rows_in(store, result.data[:key])
        assert_equal rows.sort, rows
        assert_includes rows, [@user.id, books_books(:war_and_peace).id]
        assert_equal rows.size, result.data[:rows]
        assert result.data[:pointer_moved]
        assert_equal "2026-10-09", store.read_pointer(Paths.interactions_latest(:books))
        assert_equal "user_id,item_id", Zlib.gunzip(store.get(result.data[:key])).lines.first.strip
      end
    end

    test "a hold-out omits exactly those pairs and leaves the pointer alone" do
      Dir.mktmpdir do |dir|
        store = Store::Local.new(dir)
        store.write_pointer(Paths.interactions_latest(:books), "2026-10-01")
        held = {@user.id => [books_books(:war_and_peace).id]}
        result = Export.call(domain: :books, store: store, name: "2026-10-09-holdout-42", hold_out: held)
        assert result.success?
        rows = rows_in(store, result.data[:key])
        assert_not_includes rows, [@user.id, books_books(:war_and_peace).id]
        assert_includes rows, [@user.id, books_books(:got).id]
        assert_equal 1, result.data[:omitted]
        assert_not result.data[:pointer_moved]
        assert_equal "2026-10-01", store.read_pointer(Paths.interactions_latest(:books))
      end
    end

    test "an unknown domain is a failure, not an exception" do
      Dir.mktmpdir do |dir|
        result = Export.call(domain: :music, store: Store::Local.new(dir))
        assert_not result.success?
        assert_match(/music/, result.errors.first)
      end
    end
  end
end
