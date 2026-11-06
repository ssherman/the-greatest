require "test_helper"

# == Schema Information
#
# Table name: books_goodreads_searches
#
#  id             :bigint           not null, primary key
#  fetched_at     :datetime         not null
#  http_status    :integer
#  outcome        :integer          not null
#  parser_version :integer
#  query          :string           not null
#  rows           :jsonb            not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Indexes
#
#  index_books_goodreads_searches_on_query  (query) UNIQUE
#
module Books
  class GoodreadsSearchTest < ActiveSupport::TestCase
    def search(query, outcome: :found, fetched_at: Time.current, rows: [])
      ::Books::GoodreadsSearch.create!(query: query, outcome: outcome, fetched_at: fetched_at, rows: rows)
    end

    test "fresh keeps found and no_results rows under 30 days and drops older and blocked ones" do
      kept = search("a")
      empty = search("b", outcome: :no_results)
      search("c", fetched_at: 31.days.ago)
      search("d", outcome: :blocked)
      search("e", outcome: :unparseable)

      assert_equal [kept, empty].sort_by(&:id), ::Books::GoodreadsSearch.fresh.order(:id).to_a
    end

    test "the query is downcased, squeezed and stripped, on write and on lookup" do
      stored = search("  Catch-22   Joseph ")

      assert_equal "catch-22 joseph", stored.query
      assert_equal stored, ::Books::GoodreadsSearch.find_by(query: "  CATCH-22  Joseph ")
      assert_equal stored, ::Books::GoodreadsSearch.find_by(query: "  Catch-22   Joseph ")
    end

    test "candidate_rows rebuilds the stored rows" do
      stored = search("catch-22", rows: [{"goodreads_book_id" => 168668, "title" => "Catch-22", "author_names" => ["Joseph Heller"],
                                          "year" => 1961, "ratings_count" => 907_547, "editions_count" => 521}])

      row = stored.candidate_rows.first
      assert_instance_of ::Books::Goodreads::SearchPage::Row, row
      assert_equal [168668, "Catch-22", ["Joseph Heller"], 1961], [row.goodreads_book_id, row.title, row.author_names, row.year]
    end
  end
end
