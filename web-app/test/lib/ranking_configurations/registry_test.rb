# frozen_string_literal: true

require "test_helper"

module RankingConfigurations
  class RegistryTest < ActiveSupport::TestCase
    test "books has exactly one entry" do
      entries = Registry.for_domain(:books)

      assert_equal 1, entries.size
      entry = entries.first
      assert_equal "books", entry.kind
      assert_equal "Books::RankingConfiguration", entry.ranking_configuration_class
      assert_equal "Books::List", entry.list_class
      assert_equal ["Global::Penalty", "Books::Penalty"], entry.penalty_classes
    end

    test "for_domain accepts a string and returns nothing for a domain with no entry" do
      assert_equal 1, Registry.for_domain("books").size
      assert_empty Registry.for_domain(:games)
      assert_empty Registry.for_domain(:music)
    end

    test "find resolves an entry by domain and kind" do
      assert_equal "Books::RankingConfiguration", Registry.find(:books, "books").ranking_configuration_class
      assert_nil Registry.find(:books, "albums")
      assert_nil Registry.find(:games, "games")
    end

    test "for_config resolves an entry from the record's STI type" do
      assert_equal "books", Registry.for_config(ranking_configurations(:books_user)).kind
      assert_nil Registry.for_config(ranking_configurations(:games_global))
    end

    test "path lambdas produce the public /rc/ URLs" do
      config = ranking_configurations(:books_user_shared)
      entry = Registry.for_config(config)
      list = lists(:books_list)

      assert_equal "/rc/#{config.id}", entry.results_path.call(config)
      assert_equal "/rc/#{config.id}/lists", entry.lists_path.call(config)
      assert_equal "/lists/#{list.id}", entry.list_path.call(list)
      assert_equal "/", entry.official_rankings_path.call
    end

    test "penalties_for returns the catalogue for the entry, excluding user-specific penalties" do
      entry = Registry.find(:books, "books")
      penalties = Registry.penalties_for(entry)

      assert_includes penalties, penalties(:global_penalty)
      assert_includes penalties, penalties(:books_penalty)
      refute_includes penalties, penalties(:user_penalty)
      refute_includes penalties, penalties(:user_books_penalty)
      refute_includes penalties, penalties(:games_penalty)
    end
  end
end
