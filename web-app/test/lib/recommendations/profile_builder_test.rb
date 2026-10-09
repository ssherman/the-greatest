# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ProfileBuilderTest < ActiveSupport::TestCase
    FICTION = 1
    NONFICTION = 2
    COMMON = 10    # genre on 55% of the catalog
    RARE = 11      # genre on 0.6%
    SUBJ = 20
    LOC = 30
    HATED = 40     # subject only on the disliked book

    def fact(id, type, count)
      CategoryFact.new(id: id, category_type: type, item_count: count)
    end

    # 20 positive books, every one Fiction + COMMON; books 1-3 also RARE; book 1 also SUBJ + LOC.
    def positive_categories
      (1..20).to_h do |i|
        cats = [fact(FICTION, "genre", 550), fact(COMMON, "genre", 550)]
        cats << fact(RARE, "genre", 6) if i <= 3
        cats += [fact(SUBJ, "subject", 40), fact(LOC, "location", 30)] if i == 1
        [i, cats]
      end
    end

    def positives
      (1..20).map { |i| Interaction.new(item_id: i, weight: 1.0, kind: :read, rating: nil) }
    end

    def build(interactions:, categories:, **overrides)
      ProfileBuilder.call(
        interactions: interactions, categories: categories, catalog_size: 1000,
        type_category_ids: {"Fiction" => FICTION, "Nonfiction" => NONFICTION},
        config: Config.resolve(overrides)
      )
    end

    def weight(profile, id)
      profile.weight_for(id)
    end

    test "a ubiquitous category scores near zero and a rare one scores high" do
      profile = build(interactions: positives, categories: positive_categories)
      assert_operator weight(profile, COMMON), :<, 0.5
      assert_operator weight(profile, RARE), :>, 2.5
      assert_equal RARE, profile.genres.first.first
    end

    test "with lift off the profile is a raw frequency share, so the common category wins" do
      profile = build(interactions: positives, categories: positive_categories, lift: false)
      assert_operator weight(profile, COMMON), :>, weight(profile, RARE)
    end

    test "lift_cap clips the lift weight; zero means uncapped" do
      capped = build(interactions: positives, categories: positive_categories, lift_cap: 1.5)
      assert_in_delta 1.5, weight(capped, RARE), 0.0001
      assert_operator weight(capped, COMMON), :<, 0.5, "the cap only touches weights above it"
      assert_equal RARE, capped.genres.first.first

      uncapped = build(interactions: positives, categories: positive_categories, lift_cap: 0)
      assert_operator weight(uncapped, RARE), :>, 2.5
    end

    test "lift_cap never caps the negative profile, so demotion survives a low cap" do
      hated = Interaction.new(item_id: 99, weight: -1.5, kind: :review, rating: 1)
      cats = positive_categories.merge(99 => [fact(FICTION, "genre", 550), fact(HATED, "subject", 20)])
      profile = build(interactions: positives + [hated], categories: cats, lift_cap: 0.5)
      assert_includes profile.demoted, HATED
      assert_in_delta 0.5, weight(profile, RARE), 0.0001
    end

    test "lift_cap does nothing with lift off" do
      profile = build(interactions: positives, categories: positive_categories, lift: false, lift_cap: 0.01)
      assert_operator weight(profile, COMMON), :>, 0.01
    end

    test "a category needs min_support positive books once the history is big enough" do
      profile = build(interactions: positives, categories: positive_categories)
      assert_nil weight(profile, SUBJ), "SUBJ appears on one book of twenty"
      small = build(interactions: positives.first(2), categories: positive_categories.slice(1, 2))
      assert_not_nil weight(small, SUBJ), "a tiny history keeps single-book categories"
    end

    test "Fiction and Nonfiction are never scored but set fiction_share and the genre distribution" do
      profile = build(interactions: positives, categories: positive_categories)
      assert_nil weight(profile, FICTION)
      assert_in_delta 1.0, profile.fiction_share, 0.001
      assert_in_delta 1.0, profile.genre_distribution.values.sum, 0.0001
      assert_in_delta profile.genre_distribution[FICTION], profile.genre_distribution[COMMON], 0.05
    end

    test "fiction_share is nil when no positive book carries a type" do
      cats = {1 => [fact(COMMON, "genre", 550)]}
      profile = build(interactions: positives.first(1), categories: cats)
      assert_nil profile.fiction_share
    end

    test "a disliked category with no positive weight is demoted, not scored" do
      hated = Interaction.new(item_id: 99, weight: -1.5, kind: :review, rating: 1)
      cats = positive_categories.merge(99 => [fact(FICTION, "genre", 550), fact(HATED, "subject", 20)])
      profile = build(interactions: positives + [hated], categories: cats)
      assert_includes profile.demoted, HATED
      assert_nil weight(profile, HATED)
    end

    test "a disliked category that is also liked is reduced by gamma, not demoted" do
      hated = Interaction.new(item_id: 99, weight: -1.5, kind: :review, rating: 1)
      cats = positive_categories.merge(99 => [fact(RARE, "genre", 6)])
      with = build(interactions: positives + [hated], categories: cats)
      without = build(interactions: positives, categories: positive_categories)
      assert_operator weight(with, RARE), :<, weight(without, RARE)
      assert_not_includes with.demoted, RARE
    end

    test "caps each type" do
      cats = (1..20).to_h { |i| [i, (100..110).map { |g| fact(g, "genre", 5) }] }
      profile = build(interactions: positives, categories: cats, max_genres: 3)
      assert_equal 3, profile.genres.size
    end

    test "an empty history yields an empty profile" do
      profile = build(interactions: [], categories: {})
      assert profile.empty?
      assert_equal({favorites: 0, read: 0, rated: 0, positive: 0, negative: 0}, profile.counts)
    end

    test "counts reflect kinds and ratings" do
      ints = [
        Interaction.new(item_id: 1, weight: 3.5, kind: :favorite, rating: 5),
        Interaction.new(item_id: 2, weight: 0.4, kind: :read, rating: nil),
        Interaction.new(item_id: 3, weight: -1.5, kind: :review, rating: 1)
      ]
      profile = build(interactions: ints, categories: positive_categories)
      assert_equal({favorites: 1, read: 1, rated: 2, positive: 2, negative: 1}, profile.counts)
    end
  end
end
