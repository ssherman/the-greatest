require "test_helper"

# == Schema Information
#
# Table name: goodreads_books
#
#  id                        :bigint           not null, primary key
#  additional_authors        :string
#  asin                      :string
#  author                    :string
#  authors                   :string           default([]), is an Array
#  average_rating            :decimal(, )
#  binding                   :string
#  description               :text
#  format                    :string
#  genres                    :string           default([]), is an Array
#  image_url                 :string
#  isbn                      :string
#  isbn13                    :string
#  language                  :string
#  last_looked_up_at         :datetime
#  last_refreshed_at         :datetime
#  locations                 :string           default([]), is an Array
#  number_of_pages           :integer
#  number_of_ratings         :integer
#  number_of_reviews         :integer
#  original_publication_year :integer
#  publisher                 :string
#  series                    :string
#  title                     :string
#  year_published            :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  goodreads_id              :string           not null
#
# Indexes
#
#  index_goodreads_books_on_goodreads_id       (goodreads_id) UNIQUE
#  index_goodreads_books_on_last_looked_up_at  (last_looked_up_at)
#  index_goodreads_books_on_last_refreshed_at  (last_refreshed_at)
#
module LegacyBooks
  class GoodreadsBookTest < ActiveSupport::TestCase
    test "reads from the legacy goodreads_books table" do
      assert_equal "goodreads_books", GoodreadsBook.table_name
    end

    # .allocate, not .new: in test LegacyBooks::Record falls back to the app's
    # own connection, which has no goodreads_books table (see blog_post_test.rb).
    test "is read only" do
      assert_predicate GoodreadsBook.allocate, :readonly?
    end
  end
end
