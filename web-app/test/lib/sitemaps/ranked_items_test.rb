require "test_helper"

module Sitemaps
  class RankedItemsTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @authors_rc = ranking_configurations(:books_authors_global)
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
      @author = books_authors(:tolstoy)
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 9)
      RankedItem.create!(item: @other, ranking_configuration: @rc, rank: 2, score: 8)
      RankedItem.create!(item: @author, ranking_configuration: @authors_rc, rank: 1, score: 9)
    end

    def books_source
      Sitemaps::RankedItems.new(key: "books", scope: ::Books::Book.catalog,
        ranking_configuration_class: ::Books::RankingConfiguration, path_prefix: "/book/")
    end

    def authors_source
      Sitemaps::RankedItems.new(key: "authors", scope: ::Books::Author.catalog,
        ranking_configuration_class: ::Books::Authors::RankingConfiguration, path_prefix: "/author/")
    end

    def paths(source) = source.entries(offset: 0, limit: 1000).map(&:path)

    test "key is the one given" do
      assert_equal "books", books_source.key
    end

    test "includes a ranked book with updated_at as lastmod" do
      entry = books_source.entries(offset: 0, limit: 1000).find { |e| e.path == "/book/#{@book.slug}" }
      assert entry
      assert_equal @book.updated_at, entry.lastmod
    end

    test "excludes a provisional book" do
      @book.update!(provisional: true)
      assert_not_includes paths(books_source), "/book/#{@book.slug}"
    end

    test "excludes a ranked item whose rank is nil" do
      RankedItem.where(item: @book).update_all(rank: nil)
      assert_not_includes paths(books_source), "/book/#{@book.slug}"
    end

    test "excludes a book ranked only in a non-primary configuration" do
      RankedItem.where(item: @book).delete_all
      RankedItem.create!(item: @book, ranking_configuration: ranking_configurations(:books_user), rank: 1, score: 1)
      assert_not_includes paths(books_source), "/book/#{@book.slug}"
    end

    test "count matches entries and offset pages in id order" do
      source = books_source
      all = source.entries(offset: 0, limit: 1000)
      assert_equal all.size, source.count
      assert_equal 2, all.size
      assert_equal [all[1]], source.entries(offset: 1, limit: 1)
      assert_equal [@book, @other].sort_by(&:id).map { |b| "/book/#{b.slug}" }, all.map(&:path)
    end

    test "lastmod is the max updated_at" do
      assert_equal [@book, @other].map(&:updated_at).max, books_source.lastmod
    end

    test "is empty when there is no primary configuration" do
      ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
      source = books_source
      assert_equal 0, source.count
      assert_equal [], source.entries(offset: 0, limit: 1000)
      assert_nil source.lastmod
    end

    test "authors list ranked authors and exclude provisional ones" do
      assert_includes paths(authors_source), "/author/#{@author.slug}"
      @author.update!(provisional: true)
      assert_not_includes paths(authors_source), "/author/#{@author.slug}"
    end
  end
end
