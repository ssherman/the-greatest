# == Schema Information
#
# Table name: external_links
#
#  id              :bigint           not null, primary key
#  click_count     :integer          default(0), not null
#  description     :text
#  link_category   :integer
#  metadata        :jsonb
#  name            :string           not null
#  parent_type     :string           not null
#  price_cents     :integer
#  public          :boolean          default(TRUE), not null
#  source          :integer
#  source_name     :string
#  url             :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  parent_id       :bigint           not null
#  submitted_by_id :bigint
#
# Indexes
#
#  index_external_links_on_click_count                (click_count)
#  index_external_links_on_parent                     (parent_type,parent_id)
#  index_external_links_on_parent_type_and_parent_id  (parent_type,parent_id)
#  index_external_links_on_public                     (public)
#  index_external_links_on_source                     (source)
#  index_external_links_on_submitted_by_id            (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
require "test_helper"

class ExternalLinkTest < ActiveSupport::TestCase
  def setup
    @external_link = external_links(:david_bowie_amazon)
    @private_link = external_links(:private_link)
    @custom_source = external_links(:custom_source_link)
  end

  # Basic validation tests
  test "should be valid with valid attributes" do
    assert @external_link.valid?
  end

  test "should require name" do
    @external_link.name = nil
    assert_not @external_link.valid?
    assert_includes @external_link.errors[:name], "can't be blank"
  end

  test "should require url" do
    @external_link.url = nil
    assert_not @external_link.valid?
    assert_includes @external_link.errors[:url], "can't be blank"
  end

  test "should validate url format" do
    @external_link.url = "not-a-url"
    assert_not @external_link.valid?
    assert_includes @external_link.errors[:url], "is invalid"
  end

  test "should accept valid http and https urls" do
    @external_link.url = "http://example.com"
    assert @external_link.valid?

    @external_link.url = "https://example.com"
    assert @external_link.valid?
  end

  test "should require source_name when source is other" do
    @custom_source.source_name = nil
    assert_not @custom_source.valid?
    assert_includes @custom_source.errors[:source_name], "can't be blank"
  end

  test "should not require source_name when source is not other" do
    @external_link.source_name = nil
    assert @external_link.valid?
  end

  test "should validate positive price_cents" do
    @external_link.price_cents = -100
    assert_not @external_link.valid?
    assert_includes @external_link.errors[:price_cents], "must be greater than 0"
  end

  test "should validate non-negative click_count" do
    @external_link.click_count = -1
    assert_not @external_link.valid?
    assert_includes @external_link.errors[:click_count], "must be greater than or equal to 0"
  end

  # Enum tests
  test "should have correct source enum values" do
    assert_equal 0, ExternalLink.sources[:amazon]
    assert_equal 1, ExternalLink.sources[:goodreads]
    assert_equal 6, ExternalLink.sources[:other]
  end

  test "should have correct link_category enum values" do
    assert_equal 0, ExternalLink.link_categories[:product_link]
    assert_equal 1, ExternalLink.link_categories[:review]
    assert_equal 2, ExternalLink.link_categories[:information]
    assert_equal 3, ExternalLink.link_categories[:misc]
  end

  # Association tests
  test "should belong to parent polymorphically" do
    assert_equal "Music::Artist", @external_link.parent_type
    assert_equal music_artists(:david_bowie), @external_link.parent
  end

  test "should belong to submitted_by user optionally" do
    assert_nil @external_link.submitted_by

    # Should allow setting a user
    @external_link.submitted_by = users(:admin_user)
    assert @external_link.valid?

    # Should allow nil submitted_by
    @external_link.submitted_by = nil
    assert @external_link.valid?
  end

  # Scope tests
  test "public_links scope should return only public links" do
    public_links = ExternalLink.public_links
    assert_includes public_links, @external_link
    assert_not_includes public_links, @private_link
  end

  test "by_source scope should filter by source" do
    amazon_links = ExternalLink.by_source(:amazon)
    assert_includes amazon_links, @external_link
    assert_not_includes amazon_links, external_links(:beatles_discogs)
  end

  test "by_category scope should filter by category" do
    product_links = ExternalLink.by_category(:product_link)
    assert_includes product_links, @external_link
    assert_not_includes product_links, external_links(:beatles_discogs)
  end

  test "most_clicked scope should order by click_count desc" do
    most_clicked = ExternalLink.most_clicked.first
    assert_equal external_links(:beatles_discogs), most_clicked
  end

  # Instance method tests
  test "increment_click_count! should increase click count by 1" do
    original_count = @external_link.click_count
    @external_link.increment_click_count!
    assert_equal original_count + 1, @external_link.reload.click_count
  end

  test "display_price should format price correctly" do
    @external_link.price_cents = 1299
    assert_equal "$12.99", @external_link.display_price

    @external_link.price_cents = 500
    assert_equal "$5.00", @external_link.display_price

    @external_link.price_cents = nil
    assert_nil @external_link.display_price
  end

  test "source_display_name should return humanized source or custom name" do
    assert_equal "Amazon", @external_link.source_display_name
    assert_equal "Last.fm", @custom_source.source_display_name
  end

  test "trackable_url should return proper redirect URL" do
    Rails.application.routes.default_url_options[:host] = "test.host"
    expected_url = Rails.application.routes.url_helpers.external_link_redirect_url(@external_link)
    assert_equal expected_url, @external_link.trackable_url
  end

  # Default values tests
  test "should have default values" do
    link = ExternalLink.new(
      name: "Test Link",
      url: "https://example.com",
      parent: music_artists(:david_bowie)
    )

    assert_equal true, link.public
    assert_equal 0, link.click_count
    # metadata is stored as JSONB string but accessed as Hash
    assert_equal({}, JSON.parse(link.metadata.to_s))
  end
end
