# frozen_string_literal: true

require "test_helper"

module Search
  class ListableAutocompleteTest < ActiveSupport::TestCase
    test "searchable? is true for supported listable types" do
      assert Search::ListableAutocomplete.searchable?("Music::Album")
      assert Search::ListableAutocomplete.searchable?("Music::Song")
      assert Search::ListableAutocomplete.searchable?("Games::Game")
    end

    test "searchable? is false for unsupported, blank, or nil types" do
      refute Search::ListableAutocomplete.searchable?("Movies::Movie")
      refute Search::ListableAutocomplete.searchable?("")
      refute Search::ListableAutocomplete.searchable?(nil)
      refute Search::ListableAutocomplete.searchable?("NotARealClass")
    end

    test "search returns [] for an unsupported type without calling any service" do
      ::Search::Music::Search::AlbumAutocomplete.expects(:call).never
      assert_equal [], Search::ListableAutocomplete.search(listable_type: "Movies::Movie", query: "x")
    end

    test "search returns [] when the service finds nothing" do
      ::Search::Music::Search::AlbumAutocomplete.stubs(:call).returns([])
      assert_equal [], Search::ListableAutocomplete.search(listable_type: "Music::Album", query: "zzzzz")
    end

    test "search serializes albums as value/text in the search service's order" do
      a1 = music_albums(:dark_side_of_the_moon)
      a2 = music_albums(:wish_you_were_here)
      ::Search::Music::Search::AlbumAutocomplete.stubs(:call).returns([
        {id: a2.id.to_s, score: 10.0, source: {}},
        {id: a1.id.to_s, score: 9.0, source: {}}
      ])

      results = Search::ListableAutocomplete.search(listable_type: "Music::Album", query: "pink")

      assert_equal [a2.id, a1.id], results.map { |r| r[:value] }
      assert_includes results.first[:text], a2.title
    end

    test "search labels games with the release year when present" do
      game = games_games(:breath_of_the_wild)
      ::Search::Games::Search::GameAutocomplete.stubs(:call).returns([{id: game.id.to_s, score: 5.0, source: {}}])

      results = Search::ListableAutocomplete.search(listable_type: "Games::Game", query: "zelda")

      expected = game.release_year.present? ? "#{game.title} (#{game.release_year})" : game.title
      assert_equal [{value: game.id, text: expected}], results
    end

    test "search passes the limit through to the service as :size" do
      ::Search::Music::Search::SongAutocomplete.expects(:call).with("money", size: 10).returns([])
      Search::ListableAutocomplete.search(listable_type: "Music::Song", query: "money")
    end
  end
end
