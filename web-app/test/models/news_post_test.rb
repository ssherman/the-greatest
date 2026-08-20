require "test_helper"

# == Schema Information
#
# Table name: news_posts
#
#  id           :bigint           not null, primary key
#  body         :text             not null
#  domain       :integer          not null
#  published_at :datetime
#  slug         :string           not null
#  summary      :text
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_news_posts_on_domain_and_published_at  (domain,published_at DESC)
#  index_news_posts_on_domain_and_slug          (domain,slug) UNIQUE
#  index_news_posts_on_user_id                  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class NewsPostTest < ActiveSupport::TestCase
  test "requires a title" do
    post = NewsPost.new(domain: :books, body: "x", user: users(:admin_user))
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  test "requires a body" do
    post = NewsPost.new(domain: :books, title: "x", user: users(:admin_user))
    assert_not post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end

  test "generates a slug from the title" do
    post = NewsPost.create!(domain: :books, title: "A Big Update", body: "hi", user: users(:admin_user))
    assert_equal "a-big-update", post.slug
  end

  test "the slug does not change when the title changes" do
    post = NewsPost.create!(domain: :books, title: "A Big Update", body: "hi", user: users(:admin_user))
    post.update!(title: "A Bigger Update")

    assert_equal "a-big-update", post.slug
  end

  test "published excludes drafts and future posts" do
    assert_equal [news_posts(:books_december_update).id],
      NewsPost.books.published.pluck(:id)
  end

  test "published includes a post published exactly now" do
    post = NewsPost.create!(domain: :books, title: "Now", body: "hi",
      user: users(:admin_user), published_at: Time.current)

    assert_includes NewsPost.books.published.pluck(:id), post.id
  end

  test "recent orders by published_at descending" do
    older = news_posts(:books_december_update)
    newer = NewsPost.create!(domain: :books, title: "Newer", body: "hi",
      user: users(:admin_user), published_at: 1.hour.ago)

    assert_equal [newer.id, older.id], NewsPost.books.published.recent.pluck(:id)
  end

  test "published? is false for a draft" do
    assert_not news_posts(:books_draft).published?
    assert news_posts(:books_draft).draft?
  end

  test "published? is false for a future publish date" do
    assert_not news_posts(:books_scheduled).published?
  end

  test "published? is true for a past publish date" do
    assert news_posts(:books_december_update).published?
    assert_not news_posts(:books_december_update).draft?
  end

  # The has_many :through from NewsPost to NewsTopic is exercised in
  # test/models/news_post_topic_test.rb, which is where the join model and its
  # fixtures are created.

  test "excerpt uses the summary when present" do
    assert_equal "The December update.", news_posts(:books_december_update).excerpt
  end

  test "excerpt falls back to the rendered body as plain text" do
    post = NewsPost.new(domain: :books, title: "x", body: "# Heading\n\nFirst line.\n\nSecond line.")

    assert_equal "Heading First line. Second line.", post.excerpt
  end

  test "excerpt truncates at the limit" do
    post = NewsPost.new(domain: :books, title: "x", body: "word " * 200)

    assert_operator post.excerpt(limit: 50).length, :<=, 50
  end

  test "to_param is the slug" do
    assert_equal "december-update", news_posts(:books_december_update).to_param
  end
end
