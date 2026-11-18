require "test_helper"

# == Schema Information
#
# Table name: books_publisher_titles
#
#  id              :bigint           not null, primary key
#  age_range       :string
#  contributors    :jsonb            not null
#  cover_url       :string
#  description     :text
#  first_read_at   :datetime
#  formats         :jsonb            not null
#  genres          :jsonb            not null
#  hold_reason     :integer
#  imprint_name    :string
#  isbn13s         :string           default([]), not null, is an Array
#  language        :string
#  last_read_at    :datetime
#  on_sale_on      :date
#  parser_version  :integer
#  publisher_name  :string
#  series_name     :string
#  series_position :string
#  source          :string           not null
#  source_key      :string
#  status          :integer          default("ready"), not null
#  subtitle        :string
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_books_publisher_titles_on_isbn13s                (isbn13s) USING gin
#  index_books_publisher_titles_on_on_sale_on             (on_sale_on)
#  index_books_publisher_titles_on_source_and_source_key  (source,source_key) UNIQUE WHERE (source_key IS NOT NULL)
#  index_books_publisher_titles_on_source_and_status      (source,status)
#
class Books::PublisherTitleTest < ActiveSupport::TestCase
  test "held needs a reason and ready must not have one" do
    held = Books::PublisherTitle.new(source: "hachette_us", status: :held)
    assert_not held.valid?
    assert held.errors[:hold_reason].any?

    held.hold_reason = :set
    assert held.valid?

    ready = Books::PublisherTitle.new(source: "hachette_us", status: :ready, hold_reason: :incomplete)
    assert_not ready.valid?
    assert ready.errors[:hold_reason].any?

    ready.hold_reason = nil
    assert ready.valid?
  end

  test "a title needs a source" do
    assert_not Books::PublisherTitle.new(source: nil).valid?
  end

  test "upcoming_first puts the soonest on-sale date first and undated titles last" do
    later = Books::PublisherTitle.create!(source: "ordering_test", on_sale_on: Date.new(2027, 6, 1))
    undated = Books::PublisherTitle.create!(source: "ordering_test", on_sale_on: nil)
    sooner = Books::PublisherTitle.create!(source: "ordering_test", on_sale_on: Date.new(2027, 1, 1))
    same_day = Books::PublisherTitle.create!(source: "ordering_test", on_sale_on: Date.new(2027, 1, 1))

    ordered = Books::PublisherTitle.where(source: "ordering_test").upcoming_first.to_a
    assert_equal [sooner, same_day, later, undated], ordered
  end

  test "listings are kept, unlinked, when a title is destroyed" do
    title = books_publisher_titles(:ready_title)
    listing = books_publisher_listings(:read_listing)
    assert_equal title, listing.publisher_title

    title.destroy!

    assert Books::PublisherListing.exists?(listing.id)
    assert_nil listing.reload.publisher_title_id
  end
end
