require "test_helper"

# == Schema Information
#
# Table name: books_publisher_listings
#
#  id                   :bigint           not null, primary key
#  attempts             :integer          default(0), not null
#  external_key         :string
#  first_seen_at        :datetime         not null
#  http_status          :integer
#  last_attempt_at      :datetime
#  last_attempt_outcome :integer
#  last_seen_at         :datetime         not null
#  outcome              :integer
#  parser_version       :integer
#  queued_at            :datetime
#  read_at              :datetime
#  signal               :string
#  source               :string           not null
#  state                :integer          default("pending"), not null
#  url                  :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  publisher_title_id   :bigint
#
# Indexes
#
#  index_books_publisher_listings_on_publisher_title_id       (publisher_title_id)
#  index_books_publisher_listings_on_source_and_external_key  (source,external_key)
#  index_books_publisher_listings_on_source_and_state         (source,state)
#  index_books_publisher_listings_on_source_and_url           (source,url) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (publisher_title_id => books_publisher_titles.id) ON DELETE => nullify
#
class Books::PublisherListingTest < ActiveSupport::TestCase
  def build_listing(**attrs)
    Books::PublisherListing.new({source: "hachette_us", url: "https://example.com/a",
                                 first_seen_at: Time.current, last_seen_at: Time.current}.merge(attrs))
  end

  test "a url is unique within its source and reusable across sources" do
    existing = books_publisher_listings(:pending_listing)

    duplicate = build_listing(source: existing.source, url: existing.url)
    assert_not duplicate.valid?
    assert duplicate.errors[:url].any?

    other_source = build_listing(source: "macmillan_us", url: existing.url)
    assert other_source.valid?
  end

  test "a listing needs a source and a url" do
    assert_not build_listing(source: nil).valid?
    assert_not build_listing(url: nil).valid?
  end

  test "a new listing is pending by default and has made no attempts" do
    listing = Books::PublisherListing.new
    assert listing.state_pending?
    assert_equal 0, listing.attempts
  end

  test "state, outcome and last attempt outcome are separate enums with prefixed predicates" do
    listing = books_publisher_listings(:read_listing)
    assert listing.state_read?
    assert listing.outcome_found?
    assert listing.last_attempt_found?

    listing.last_attempt_outcome = :unavailable
    assert listing.last_attempt_unavailable?
    assert listing.outcome_found?
    assert listing.state_read?
  end

  test "the page attaches to the private imports service" do
    assert_equal :private_imports, Books::PublisherListing.reflect_on_attachment(:html).options[:service_name]
  end
end
