# frozen_string_literal: true

require "test_helper"

module CsvExports
  class RegistryTest < ActiveSupport::TestCase
    test "the four ranking domains are exportable" do
      %i[books_global music_albums_global music_songs_global games_global].each do |name|
        assert Registry.exportable?(ranking_configurations(name)), "#{name} should be exportable"
      end
    end

    test "creator rankings and movies are not exportable" do
      %i[books_authors_global music_artists_global movies_global].each do |name|
        refute Registry.exportable?(ranking_configurations(name)), "#{name} should not be exportable"
        assert_nil Registry.for_config(ranking_configurations(name))
      end
    end

    test "an entry names its row class, slug and noun" do
      entry = Registry.for_config(ranking_configurations(:books_global))

      assert_equal "CsvExports::Books::RankedBookRow", entry.row_class_name
      assert_equal "books", entry.slug
      assert_equal "books", entry.noun
    end

    test "media_table names the table the year filter addresses; books has none" do
      assert_equal "music_albums", Registry.for_config(ranking_configurations(:music_albums_global)).media_table
      assert_nil Registry.for_config(ranking_configurations(:books_global)).media_table
    end

    test "the unfiltered relation is the configuration's ranked items in rank order" do
      config = ranking_configurations(:games_global)

      ids = Registry.for_config(config).relation.call(config).pluck(:item_id)

      assert_equal [
        games_games(:breath_of_the_wild).id,
        games_games(:resident_evil_4).id,
        games_games(:half_life_2).id,
        games_games(:tears_of_the_kingdom).id
      ], ids
    end

    test "the music relation excludes unranked items" do
      config = ranking_configurations(:music_songs_global)

      ids = Registry.for_config(config).relation.call(config).pluck(:item_id)

      assert_equal [music_songs(:time).id], ids
    end

    test "filenames carry the slug and the date" do
      assert_equal "the-greatest-books-rankings-2026-09-18.csv",
        Registry.filename_for(ranking_configurations(:books_global), date: Date.new(2026, 9, 18))
      assert_equal "user-books-ranking-books-2026-09-18.csv",
        Registry.filename_for(ranking_configurations(:books_user), date: Date.new(2026, 9, 18))
    end

    test "filename_for refuses a non-exportable configuration" do
      assert_raises(ArgumentError) { Registry.filename_for(ranking_configurations(:books_authors_global)) }
    end

    test "a long user-owned name is capped in the filename" do
      config = ranking_configurations(:books_user)
      config.name = "x" * 255

      assert_operator Registry.filename_for(config, date: Date.new(2026, 9, 18)).length, :<, 120
    end
  end
end
