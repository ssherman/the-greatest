# frozen_string_literal: true

require "test_helper"

module Recommendations
  class RerankerTest < ActiveSupport::TestCase
    def cand(id, score: 1.0)
      Candidate.new(item_id: id, score: score, rank_position: nil, evidence: {})
    end

    def fact(authors: [], genres: [], predecessor: nil)
      ItemFact.new(author_ids: authors, genre_ids: genres, series_predecessor_id: predecessor, rank_position: nil)
    end

    test "author cap keeps the first max_per_author books per author and skips the rest" do
      facts = {1 => fact(authors: [7]), 2 => fact(authors: [7]), 3 => fact(authors: [8]), 4 => fact(authors: [7, 8])}
      kept = Reranker::AuthorCap.call([cand(1), cand(2), cand(3), cand(4)], facts: facts, config: Config.resolve(max_per_author: 1))
      assert_equal [1, 3], kept.map(&:item_id), "4 is skipped because both its authors are already at the cap"
    end

    test "author cap passes books with no known author" do
      kept = Reranker::AuthorCap.call([cand(1), cand(2)], facts: {1 => fact, 2 => fact}, config: Config.resolve(max_per_author: 1))
      assert_equal [1, 2], kept.map(&:item_id)
    end

    test "series rule drops a sequel unless the predecessor is a favorite, read, reading, or rated book" do
      facts = {10 => fact(predecessor: 1), 11 => fact(predecessor: 2), 12 => fact(predecessor: 3), 13 => fact(predecessor: 4), 14 => fact}
      interactions = [
        Interaction.new(item_id: 1, weight: 2.0, kind: :favorite, rating: nil),
        Interaction.new(item_id: 2, weight: 0.2, kind: :want_to_read, rating: nil),
        Interaction.new(item_id: 3, weight: 0.0, kind: :review, rating: 3)
      ]
      kept = Reranker::SeriesRule.call([cand(10), cand(11), cand(12), cand(13), cand(14)], facts: facts, interactions: interactions)
      assert_equal [10, 12, 14], kept.map(&:item_id), "11's predecessor is only wanted; 13's is unknown"
    end

    test "genre calibration pulls an under-represented genre into the page" do
      a_books = (1..10).map { |i| cand(i, score: 11 - i) }
      b_books = (11..15).map { |i| cand(i, score: (16 - i) / 10.0) }
      facts = (1..10).to_h { |i| [i, fact(genres: [100])] }.merge((11..15).to_h { |i| [i, fact(genres: [200])] })
      history = {100 => 0.7, 200 => 0.3}

      page = Reranker::GenreCalibration.call(a_books + b_books, facts: facts, history: history, limit: 10, config: Config.resolve)
      assert_equal 10, page.size
      assert_equal 1, page.first.item_id, "the strongest book still leads"
      assert_operator page.count { |c| c.item_id > 10 }, :>=, 1

      off = Reranker::GenreCalibration.call(a_books + b_books, facts: facts, history: history, limit: 10, config: Config.resolve(calibrate_genres: false))
      assert_equal (1..10).to_a, off.map(&:item_id)
    end

    test "genre calibration is a no-op for an empty history and returns at most limit" do
      page = Reranker::GenreCalibration.call([cand(1), cand(2), cand(3)], facts: {}, history: {}, limit: 2, config: Config.resolve)
      assert_equal [1, 2], page.map(&:item_id)
    end
  end
end
