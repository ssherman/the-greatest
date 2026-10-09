# frozen_string_literal: true

require "test_helper"

module Recommendations
  class TasteComponentTest < ViewComponent::TestCase
    def profile(genres: [], subjects: [], locations: [], counts: {favorites: 2, read: 7, rated: 3})
      Recommendations::Profile.new(genres: genres, subjects: subjects, locations: locations, demoted: [],
        fiction_share: nil, genre_distribution: {}, counts: counts)
    end

    test "lists each type with a bar scaled to the strongest weight" do
      render_inline(TasteComponent.new(profile: profile(genres: [[1, 4.0], [2, 2.0]], subjects: [[3, 1.0]]),
        names: {1 => "Dark", 2 => "Tragedy", 3 => "Guilt"}))
      assert_selector "[data-testid='taste-genre']", count: 2
      assert_selector "[data-testid='taste-subject']", count: 1
      assert_selector "[data-testid='taste-location']", count: 0
      assert_selector "[data-testid='taste-genre'] progress[value='100'][max='100']"
      assert_selector "[data-testid='taste-genre'] progress[value='50'][max='100']"
      assert_text "Dark"
    end

    test "caps each type and skips an id with no name" do
      genres = (1..8).map { |i| [i, 9.0 - i] }
      names = (1..8).to_h { |i| [i, "G#{i}"] }.except(2)
      render_inline(TasteComponent.new(profile: profile(genres: genres), names: names, max_per_type: 3))
      assert_selector "[data-testid='taste-genre']", count: 3
      assert_no_text "G2"
      assert_text "G4"
    end

    test "renders the counts line" do
      render_inline(TasteComponent.new(profile: profile, names: {}))
      assert_selector "[data-testid='taste-counts']", text: /2 favorites.*7 read.*3 rated/
    end
  end
end
