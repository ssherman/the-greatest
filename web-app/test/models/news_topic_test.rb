require "test_helper"

# == Schema Information
#
# Table name: news_topics
#
#  id         :bigint           not null, primary key
#  domain     :integer          not null
#  name       :string           not null
#  slug       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_news_topics_on_domain_and_slug  (domain,slug) UNIQUE
#
class NewsTopicTest < ActiveSupport::TestCase
  test "requires a name" do
    topic = NewsTopic.new(domain: :books)
    assert_not topic.valid?
    assert_includes topic.errors[:name], "can't be blank"
  end

  test "requires a domain" do
    topic = NewsTopic.new(name: "Rankings")
    assert_not topic.valid?
    assert_includes topic.errors[:domain], "can't be blank"
  end

  test "generates a slug from the name" do
    topic = NewsTopic.create!(domain: :books, name: "Data Updates")
    assert_equal "data-updates", topic.slug
  end

  test "the same slug may exist once per domain" do
    NewsTopic.create!(domain: :books, name: "Release Notes")
    music = NewsTopic.create!(domain: :music, name: "Release Notes")

    assert_equal "release-notes", music.slug
  end

  test "a duplicate slug within one domain gets a suffix" do
    NewsTopic.create!(domain: :books, name: "Patch Notes")
    second = NewsTopic.create!(domain: :books, name: "Patch Notes")

    assert_not_equal "patch-notes", second.slug
  end

  test "the slug does not change when the name changes" do
    topic = NewsTopic.create!(domain: :books, name: "Weekly Digest")
    topic.update!(name: "Monthly Digest")

    assert_equal "weekly-digest", topic.slug
  end

  test "the slug does not change when the domain changes" do
    # FriendlyId's Scoped module regenerates the slug whenever a scope column
    # changes. should_generate_new_friendly_id? overrides that so the slug --
    # a public URL -- is frozen no matter what changes on the record.
    #
    # Asserting only the post-save slug value would not catch a regression
    # here: "Rankings" normalizes to "rankings" whether or not it regenerates,
    # since no other :games topic holds that slug, so the outcome looks the
    # same either way. Asserting the predicate directly does discriminate:
    # with the override removed, Scoped's own version flips this to true as
    # soon as :domain is dirty.
    topic = news_topics(:books_rankings)
    topic.domain = :games

    assert_not topic.should_generate_new_friendly_id?

    topic.save!
    assert_equal "rankings", topic.slug
  end

  test "sorted_by_name orders alphabetically" do
    # Deliberately NOT fixture-id order -- a sort assertion that coincides with
    # id order passes against a deleted order clause.
    names = NewsTopic.books.sorted_by_name.pluck(:name)
    assert_equal names.sort, names
  end

  test "to_param is the slug" do
    assert_equal news_topics(:books_rankings).slug, news_topics(:books_rankings).to_param
  end

  test "domain enum maps books to 2, matching DomainRole" do
    assert_equal DomainRole.domains["books"], NewsTopic.domains["books"]
    assert_equal DomainRole.domains["music"], NewsTopic.domains["music"]
    assert_equal DomainRole.domains["games"], NewsTopic.domains["games"]
  end
end
