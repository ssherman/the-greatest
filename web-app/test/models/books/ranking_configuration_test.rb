require "test_helper"

module Books
  class RankingConfigurationTest < ActiveSupport::TestCase
    test "ranking_archive_class is Books::RankingArchive" do
      assert_equal ::Books::RankingArchive, ranking_configurations(:books_global).ranking_archive_class
    end

    test "ranking_archive_class is nil for another media type" do
      assert_nil ranking_configurations(:music_albums_global).ranking_archive_class
    end

    test "has_many ranking_archives" do
      assert_includes ranking_configurations(:books_global).ranking_archives, ranking_archives(:books_january_2027)
    end
  end
end
