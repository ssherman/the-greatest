# frozen_string_literal: true

require "test_helper"

module DataImporters
  class FinderRegistryTest < ActiveSupport::TestCase
    test "every finder class under app/lib/data_importers has exactly one entry" do
      files = Dir[Rails.root.join("app/lib/data_importers/**/finder.rb")]
      names = files.map { |file| file.sub(%r{.*app/lib/}, "").delete_suffix(".rb").camelize }

      assert names.any?, "no finder.rb files found -- did the layout change?"
      assert_equal names.sort, FinderRegistry::ENTRIES.map(&:finder).sort
    end

    test "each entry's finder is a FinderBase for the entry's model and its query class exists" do
      FinderRegistry::ENTRIES.each do |entry|
        assert_operator entry.finder_class, :<, FinderBase, entry.finder
        assert_equal entry.model_class, entry.finder_class.new.send(:model_class), entry.finder
        assert_operator entry.query_class, :<, DataImporters::ImportQuery, entry.finder
      end
    end

    test "a mergeable entry names a destructive admin action, a source field and an execute_action path" do
      records = {
        "Books::Book" => books_books(:war_and_peace),
        "Games::Game" => games_games(:half_life_2),
        "Music::Artist" => music_artists(:david_bowie),
        "Music::Album" => music_albums(:dark_side_of_the_moon),
        "Music::Song" => music_songs(:time)
      }

      mergeable = FinderRegistry::ENTRIES.select(&:mergeable?)
      assert_equal %w[Books::Book Games::Game Music::Album Music::Artist Music::Song], mergeable.map(&:model).sort

      mergeable.each do |entry|
        action = "Actions::Admin::#{entry.domain.to_s.camelize}::#{entry.merge_action}".constantize
        assert action.destructive?, entry.merge_action
        assert_match(/\Asource_\w+_id\z/, entry.source_field)
        assert_match %r{/admin/.+/execute_action\z}, entry.execute_action_path.call(records.fetch(entry.model))
      end
    end

    test "Games::Company is registered without a merge action" do
      entry = FinderRegistry.entry_for_model("Games::Company")

      assert_equal "DataImporters::Games::Company::Finder", entry.finder
      assert_not entry.mergeable?
      assert_nil entry.execute_action_path
    end

    test "for_domain groups entries by admin domain" do
      assert_equal ["Books::Book"], FinderRegistry.models_for(:books)
      assert_equal %w[Games::Company Games::Game], FinderRegistry.models_for(:games).sort
      assert_equal %w[Music::Album Music::Artist Music::Song], FinderRegistry.models_for("music").sort
      assert_equal ["DataImporters::Books::Book::Finder"], FinderRegistry.finders_for(:books)
      assert_empty FinderRegistry.for_domain(:movies)
    end

    test "only the books finder offers re-check" do
      assert_equal ["DataImporters::Books::Book::Finder"], FinderRegistry::ENTRIES.select(&:recheck?).map(&:finder)
    end

    test "entry lookups return nil for unknown names" do
      assert_nil FinderRegistry.entry("DataImporters::Nope::Finder")
      assert_nil FinderRegistry.entry_for_model("Books::Author")
    end
  end
end
