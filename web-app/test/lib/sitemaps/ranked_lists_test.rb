require "test_helper"

module Sitemaps
  class RankedListsTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @list = lists(:books_list)
      @list.update!(status: :active)
      RankedList.find_or_create_by!(list: @list, ranking_configuration: @rc) { |rl| rl.weight = 10 }
    end

    def source
      Sitemaps::RankedLists.new(key: "lists", list_class: ::Books::List,
        ranking_configuration_class: ::Books::RankingConfiguration, path_prefix: "/lists/")
    end

    def paths = source.entries(offset: 0, limit: 1000).map(&:path)

    test "key is the one given" do
      assert_equal "lists", source.key
    end

    test "includes an active ranked list with updated_at as lastmod" do
      entry = source.entries(offset: 0, limit: 1000).find { |e| e.path == "/lists/#{@list.id}" }
      assert entry
      assert_equal @list.updated_at, entry.lastmod
    end

    test "excludes the list once it is no longer active" do
      @list.update!(status: :approved)
      assert_not_includes paths, "/lists/#{@list.id}"
    end

    test "excludes an active list with no ranked_lists row" do
      unranked = ::Books::List.create!(name: "Unranked", status: :active)
      assert_not_includes paths, "/lists/#{unranked.id}"
    end

    test "excludes a list ranked only in another configuration" do
      RankedList.where(list: @list).delete_all
      RankedList.create!(list: @list, ranking_configuration: ranking_configurations(:books_user), weight: 1)
      assert_not_includes paths, "/lists/#{@list.id}"
    end

    test "count matches entries and lastmod is the max updated_at" do
      all = source.entries(offset: 0, limit: 1000)
      assert_equal all.size, source.count
      assert_equal all.map(&:lastmod).max, source.lastmod
    end

    test "is empty when there is no primary configuration" do
      ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
      assert_equal 0, source.count
      assert_equal [], source.entries(offset: 0, limit: 10)
    end
  end
end
