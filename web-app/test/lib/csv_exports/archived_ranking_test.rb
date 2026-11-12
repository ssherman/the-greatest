# frozen_string_literal: true

require "test_helper"

module CsvExports
  class ArchivedRankingTest < ActiveSupport::TestCase
    ID_COLUMN = Books::RankedBookRow::HEADERS.index("ID")

    setup do
      @war = books_books(:war_and_peace)
      @crime = books_books(:crime_and_punishment)
      @archive = ranking_archives(:books_january_2027)
    end

    def export(archive: @archive, limit: nil, batch: 1000)
      io = StringIO.new
      rows = ArchivedRanking.call(archive: archive, row_class: Books::RankedBookRow, limit: limit, io: io, batch: batch)
      [rows, CSV.parse(io.string.delete_prefix(Writer::BOM))]
    end

    def make_archive(item_ids, slug: "built")
      ::Books::RankingArchive.create!(
        name: slug.titleize, slug: slug, captured_at: Time.utc(2027, 1, 1, 5),
        item_ids: item_ids,
        positions: item_ids.each_index.map { |i| i + 1 },
        scores: item_ids.each_index.map { |i| 100.0 - i }
      )
    end

    test "rows follow archive order with the archived rank and score" do
      rows, parsed = export

      assert_equal 2, rows
      assert_equal Books::RankedBookRow::HEADERS, parsed.first
      data = parsed.drop(1)
      assert_equal %w[1 2], data.map { |r| r[0] }
      assert_equal [100.0, 90.0], data.map { |r| r[1].to_f }
      assert_equal [@war.id.to_s, @crime.id.to_s], data.map { |r| r[ID_COLUMN] }
    end

    test "limit caps the rows written" do
      rows, parsed = export(limit: 1)

      assert_equal 1, rows
      assert_equal 1, parsed.drop(1).size
    end

    test "a nil limit writes everything" do
      rows, _parsed = export(limit: nil)

      assert_equal 2, rows
    end

    test "a merged id is exported as its survivor at the archived rank" do
      gone_id = ::Books::Book.maximum(:id) + 1000
      ::RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @crime.id)
      archive = make_archive([@war.id, gone_id])

      _rows, parsed = export(archive: archive)

      data = parsed.drop(1)
      assert_equal [@war.id.to_s, @crime.id.to_s], data.map { |r| r[ID_COLUMN] }
      assert_equal %w[1 2], data.map { |r| r[0] }
    end

    test "deleted ids are left out and do not count toward the limit" do
      archive = make_archive([-1, -2, @war.id, @crime.id])

      rows, parsed = export(archive: archive, limit: 2, batch: 2)

      assert_equal 2, rows
      assert_equal %w[3 4], parsed.drop(1).map { |r| r[0] }
    end

    test "batches do not repeat or drop rows" do
      books = Array.new(5) { |i| ::Books::Book.create!(title: "Batch #{i}", slug: "batch-#{i}") }
      archive = make_archive(books.map(&:id))

      rows, parsed = export(archive: archive, batch: 2)

      assert_equal 5, rows
      assert_equal %w[1 2 3 4 5], parsed.drop(1).map { |r| r[0] }
      assert_equal books.map(&:title), parsed.drop(1).map { |r| r[3] }
    end
  end
end
