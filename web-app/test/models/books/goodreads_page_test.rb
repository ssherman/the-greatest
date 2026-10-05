require "test_helper"

# == Schema Information
#
# Table name: books_goodreads_pages
#
#  id                        :bigint           not null, primary key
#  asin                      :string
#  authors                   :jsonb            not null
#  fetched_at                :datetime         not null
#  http_status               :integer
#  isbn10                    :string
#  isbn13                    :string
#  original_publication_year :integer
#  outcome                   :integer          not null
#  parser_version            :integer
#  series                    :jsonb            not null
#  source                    :integer          default("fetched"), not null
#  title                     :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  goodreads_book_id         :bigint           not null
#
# Indexes
#
#  index_books_goodreads_pages_on_goodreads_book_id  (goodreads_book_id) UNIQUE
#
module Books
  class GoodreadsPageTest < ActiveSupport::TestCase
    test "found and not-found pages are conclusive; blocked and unparseable ones are fetched again" do
      blocked = GoodreadsPage.create!(goodreads_book_id: 1, outcome: :blocked, fetched_at: Time.current)
      unparseable = GoodreadsPage.create!(goodreads_book_id: 2, outcome: :unparseable, fetched_at: Time.current)

      assert_equal [books_goodreads_pages(:war_and_peace_page), books_goodreads_pages(:invented_page)].sort_by(&:id),
        GoodreadsPage.conclusive.order(:id).to_a
      assert_equal [true, true, false, false],
        [books_goodreads_pages(:war_and_peace_page), books_goodreads_pages(:invented_page), blocked, unparseable].map(&:conclusive?)
    end

    test "one page per Goodreads id" do
      duplicate = GoodreadsPage.new(goodreads_book_id: 656, outcome: :found, fetched_at: Time.current)

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:goodreads_book_id], "has already been taken"
    end

    test "the HTML is kept gzipped on the private imports service" do
      page = books_goodreads_pages(:war_and_peace_page)

      page.html.attach(io: StringIO.new(Zlib.gzip("<html>656</html>")), filename: "goodreads-656.html.gz",
        content_type: "application/gzip", identify: false)

      assert_equal "private_imports", page.html.blob.service_name
      assert_equal "<html>656</html>", Zlib.gunzip(page.html.download)
    end
  end
end
