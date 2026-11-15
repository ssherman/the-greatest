require "test_helper"

# == Schema Information
#
# Table name: books_series
#
#  id                     :bigint           not null, primary key
#  deleted                :boolean          default(FALSE), not null
#  description            :text
#  slug                   :string           not null
#  title                  :string           not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  merged_into_id         :bigint
#  representative_book_id :bigint
#
# Indexes
#
#  index_books_series_on_deleted                 (deleted)
#  index_books_series_on_merged_into_id          (merged_into_id)
#  index_books_series_on_representative_book_id  (representative_book_id)
#  index_books_series_on_slug                    (slug) UNIQUE
#  index_books_series_on_title                   (title)
#
# Foreign Keys
#
#  fk_rails_...  (merged_into_id => books_series.id) ON DELETE => nullify
#  fk_rails_...  (representative_book_id => books_books.id) ON DELETE => nullify
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

    test "destroying a representative book nullifies the link instead of raising" do
      series = Books::Series.create!(title: "Temp Series")
      book = Books::Book.create!(title: "Representative Book")
      series.update!(representative_book: book)
      assert_nothing_raised { book.destroy }
      assert_nil series.reload.representative_book_id
    end

    test "canonical returns self for a live series" do
      assert_equal books_series(:asoiaf), books_series(:asoiaf).canonical
    end

    test "canonical follows a merge to a live target" do
      assert_equal books_series(:live_target), books_series(:merged_into_live).canonical
    end

    test "canonical is nil for a junk delete" do
      assert_nil books_series(:junk_deleted).canonical
    end

    test "canonical is nil when the merge target was deleted" do
      assert_nil books_series(:merged_into_dead).canonical
    end

    test "active and merged scopes" do
      assert_includes Books::Series.active, books_series(:asoiaf)
      assert_not_includes Books::Series.active, books_series(:junk_deleted)
      assert_includes Books::Series.merged, books_series(:merged_into_live)
      assert_not_includes Books::Series.merged, books_series(:junk_deleted)
    end
  end
end
