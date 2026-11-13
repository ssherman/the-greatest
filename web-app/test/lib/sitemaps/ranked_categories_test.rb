require "test_helper"

module Sitemaps
  class RankedCategoriesTest < ActiveSupport::TestCase
    setup do
      @category = categories(:music_rock_genre)
      @album = music_albums(:dark_side_of_the_moon)
      @rc = ranking_configurations(:music_albums_global)
      RankedItem.create!(item: @album, ranking_configuration: @rc, rank: 1, score: 9)
    end

    def counts = -> { {@category.id => 3} }

    def source(minimum:, counts: self.counts, scope: ::Music::Category.active)
      Sitemaps::RankedCategories.new(key: "categories", scope: scope, counts: counts,
        path_prefix: "/categories/", minimum: minimum)
    end

    def paths(src) = src.entries(offset: 0, limit: 1000).map(&:path)

    test "key is the one given" do
      assert_equal "categories", source(minimum: 1).key
    end

    test "includes a category at the minimum, with no lastmod" do
      entry = source(minimum: 3).entries(offset: 0, limit: 1000).find { |e| e.path == "/categories/#{@category.slug}" }
      assert entry
      assert_nil entry.lastmod
      assert_nil source(minimum: 3).lastmod
    end

    test "excludes a category below the minimum" do
      assert_not_includes paths(source(minimum: 4)), "/categories/#{@category.slug}"
    end

    test "excludes a deleted category" do
      deleted = categories(:music_deleted_genre)
      src = source(minimum: 1, counts: -> { {deleted.id => 50} })
      assert_not_includes paths(src), "/categories/#{deleted.slug}"
    end

    test "count and entries paginate" do
      src = source(minimum: 1, counts: -> { ::Music::Category.active.pluck(:id).index_with { 5 } })
      assert_operator src.count, :>=, 2
      assert_equal 1, src.entries(offset: 0, limit: 1).size
      assert_equal src.count, paths(src).size
    end

    test "default minimum is Thresholds.filter_single" do
      Sitemaps::Thresholds.stubs(:filter_single).returns(3)
      src = Sitemaps::RankedCategories.new(key: "c", scope: ::Music::Category.active, counts: counts, path_prefix: "/categories/")
      assert_includes paths(src), "/categories/#{@category.slug}"
    end
  end
end
