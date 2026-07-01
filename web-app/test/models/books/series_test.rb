require "test_helper"

# == Schema Information
#
# Table name: books_series
#
#  id                     :bigint           not null, primary key
#  description            :text
#  slug                   :string           not null
#  title                  :string           not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  representative_book_id :bigint
#
# Indexes
#
#  index_books_series_on_representative_book_id  (representative_book_id)
#  index_books_series_on_slug                    (slug) UNIQUE
#  index_books_series_on_title                   (title)
#
# Foreign Keys
#
#  fk_rails_...  (representative_book_id => books_books.id)
#
module Books
  class SeriesTest < ActiveSupport::TestCase
    test "is valid with a title" do
      assert_predicate Books::Series.new(title: "Mistborn"), :valid?
    end

    test "requires a title" do
      series = Books::Series.new
      assert_not series.valid?
      assert_includes series.errors[:title], "can't be blank"
    end

    test "generates a slug from the title" do
      series = Books::Series.create!(title: "The Wheel of Time")
      assert_equal "the-wheel-of-time", series.slug
    end

    test "representative_book is optional" do
      assert_nil books_series(:asoiaf).representative_book
    end
  end
end
