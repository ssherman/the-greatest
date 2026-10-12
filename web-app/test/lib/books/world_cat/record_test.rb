require "test_helper"

module Books
  module WorldCat
    class RecordTest < ActiveSupport::TestCase
      test "from_hash reads every field and flattens holdings" do
        record = Record.from_hash(
          "oclc" => 1055766559, "title" => "Atomic habits", "subtitle" => nil, "creator" => "James Clear",
          "contributors" => ["James Clear"], "year" => 2018, "publisher" => "Avery", "publication_place" => "New York",
          "cataloging_language" => "eng", "specific_format" => "PrintBook", "edition_statement" => nil,
          "genre" => "Nonfiction", "subjects" => ["Habit"], "isbn13s" => ["9780735211292"],
          "merged_oclc" => [1], "other_format_oclc" => [2], "total_editions" => 18, "summary" => nil,
          "holdings" => {"total_holding_count" => 3097, "total_editions" => 22}, "redirected_from" => nil
        )
        assert_equal [1055766559, "Nonfiction", ["Habit"], 3097, 22], [record.oclc, record.genre, record.subjects, record.holding_count, record.holdings_editions]
        assert_nil record.redirected_from
      end

      test "from_hash tolerates missing lists and absent holdings" do
        record = Record.from_hash("oclc" => 5)
        assert_equal [[], [], [], [], []], [record.contributors, record.subjects, record.isbn13s, record.merged_oclc, record.other_format_oclc]
        assert_nil record.holding_count
      end
    end
  end
end
