# frozen_string_literal: true

require "test_helper"

module Recommendations
  class EvaluationTest < ActiveSupport::TestCase
    def interaction(id, kind: :favorite, rating: nil, weight: 2.0)
      Interaction.new(item_id: id, weight: weight, kind: kind, rating: rating)
    end

    test "split holds out a fifth of favorites and 4-plus ratings, never read-only books" do
      ints = (1..10).map { |i| interaction(i) } + [interaction(11, kind: :read, weight: 0.4), interaction(12, kind: :review, rating: 3, weight: 0.0)]
      train, held = Evaluation.split(ints, fraction: 0.2, random: Random.new(1))
      assert_equal 2, held.size
      assert held.all? { |i| i.kind == :favorite }
      assert_equal ints.size - 2, train.size
      assert_empty train.map(&:item_id) & held.map(&:item_id)
    end

    test "split is deterministic for a seed" do
      ints = (1..10).map { |i| interaction(i) }
      a = Evaluation.split(ints, fraction: 0.2, random: Random.new(7)).last.map(&:item_id)
      b = Evaluation.split(ints, fraction: 0.2, random: Random.new(7)).last.map(&:item_id)
      assert_equal a, b
    end

    test "metrics: hit, recall and ndcg" do
      m = Evaluation.metrics(page_ids: [5, 1, 9, 2] + (20..70).to_a, held_out_ids: [1, 2, 3])
      assert_equal 1, m[:hit]
      assert_in_delta 2.0 / 3, m[:recall], 1e-9
      dcg = 1 / Math.log2(3) + 1 / Math.log2(5)
      idcg = 1 / Math.log2(2) + 1 / Math.log2(3) + 1 / Math.log2(4)
      assert_in_delta dcg / idcg, m[:ndcg], 1e-9
    end

    test "metrics: no hits" do
      m = Evaluation.metrics(page_ids: [5, 6], held_out_ids: [1])
      assert_equal({hit: 0, recall: 0.0, ndcg: 0.0}, m)
    end

    test "genre_kl is zero for a matching mix and positive for a skewed one" do
      history = {1 => 0.5, 2 => 0.5}
      assert_in_delta 0.0, Evaluation.genre_kl(history: history, page_genres: [[1], [2]], alpha: 0.01), 1e-9
      assert_operator Evaluation.genre_kl(history: history, page_genres: [[1], [1], [1]], alpha: 0.01), :>, 0.5
    end

    test "genre_kl is nil when the page carries no genres or the history is empty" do
      assert_nil Evaluation.genre_kl(history: {1 => 1.0}, page_genres: [[], []], alpha: 0.01)
      assert_nil Evaluation.genre_kl(history: {1 => 1.0}, page_genres: [], alpha: 0.01)
      assert_nil Evaluation.genre_kl(history: {}, page_genres: [[1]], alpha: 0.01)
    end

    test "sample_user_ids samples only eligible users, bucketed by positive list items" do
      # regular_user has 3 books items in the fixtures (2 favorites, 1 read) -> below every segment.
      heavy = User.create!(email: "heavy@example.com")
      favorites = heavy.default_user_list_for(::Books::UserList, :favorites)
      5.times { |i| favorites.user_list_items.create!(listable: ::Books::Book.create!(title: "F#{i}")) }
      reader = User.create!(email: "reader@example.com")
      read = reader.default_user_list_for(::Books::UserList, :read)
      5.times { |i| read.user_list_items.create!(listable: ::Books::Book.create!(title: "R#{i}")) }

      sample = Evaluation.sample_user_ids(domain: :books, per_segment: 10, random: Random.new(1))
      assert_equal [heavy.id], sample["5-19"]
      assert_equal [], sample["20-99"]
      assert_equal [], sample["100+"]
      assert_not_includes sample.values.flatten, reader.id
    end

    test "sample_user_ids needs five hold-out candidates: four favorites plus read books is not enough" do
      user = User.create!(email: "four-favorites@example.com")
      favorites = user.default_user_list_for(::Books::UserList, :favorites)
      read = user.default_user_list_for(::Books::UserList, :read)
      4.times { |i| favorites.user_list_items.create!(listable: ::Books::Book.create!(title: "Fav#{i}")) }
      6.times { |i| read.user_list_items.create!(listable: ::Books::Book.create!(title: "Read#{i}")) }

      sample = Evaluation.sample_user_ids(domain: :books, per_segment: 10, random: Random.new(1))
      assert_not_includes sample.values.flatten, user.id
    end

    test "sample_user_ids counts 4-star reviews toward the eligibility floor" do
      user = User.create!(email: "reviewer@example.com")
      read = user.default_user_list_for(::Books::UserList, :read)
      5.times do |i|
        book = ::Books::Book.create!(title: "Reviewed#{i}")
        read.user_list_items.create!(listable: book)
        Review.create!(user: user, reviewable: book, rating: 4)
      end

      sample = Evaluation.sample_user_ids(domain: :books, per_segment: 10, random: Random.new(1))
      assert_equal [user.id], sample["5-19"]
    end
  end
end
