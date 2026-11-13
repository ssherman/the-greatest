require "test_helper"

module Sitemaps
  class NewsPostsTest < ActiveSupport::TestCase
    test "key is news" do
      assert_equal "news", Sitemaps::NewsPosts.new(domain: :books).key
    end

    test "lists published posts of the domain with updated_at as lastmod" do
      post = news_posts(:books_december_update)
      entries = Sitemaps::NewsPosts.new(domain: :books).entries(offset: 0, limit: 100)
      entry = entries.find { |e| e.path == "/news/#{post.slug}" }
      assert entry
      assert_equal post.updated_at, entry.lastmod
    end

    test "excludes drafts and other domains" do
      paths = Sitemaps::NewsPosts.new(domain: :books).entries(offset: 0, limit: 100).map(&:path)
      assert_not_includes paths, "/news/#{news_posts(:books_draft).slug}"
      assert_not_includes paths, "/news/#{news_posts(:music_launch).slug}"
    end

    test "count matches entries and lastmod is the max updated_at" do
      source = Sitemaps::NewsPosts.new(domain: :books)
      entries = source.entries(offset: 0, limit: 100)
      assert_equal entries.size, source.count
      assert_equal entries.map(&:lastmod).max, source.lastmod
    end
  end
end
