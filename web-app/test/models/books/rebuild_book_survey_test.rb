require "test_helper"

# == Schema Information
#
# Table name: books_rebuild_book_surveys
#
#  id             :bigint           not null, primary key
#  authors_agree  :boolean
#  classification :integer          not null
#  edition_count  :integer          default(0), not null
#  groups         :jsonb            not null
#  row_count      :integer          default(0), not null
#  surveyed_at    :datetime         not null
#  title_agrees   :boolean
#  wrong_book     :boolean          default(FALSE), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  book_id        :bigint           not null
#
# Indexes
#
#  index_books_rebuild_book_surveys_on_book_id         (book_id) UNIQUE
#  index_books_rebuild_book_surveys_on_classification  (classification)
#  index_books_rebuild_book_surveys_on_wrong_book      (wrong_book)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => cascade
#
module Books
  class RebuildBookSurveyTest < ActiveSupport::TestCase
    test "a book has one survey" do
      dup = RebuildBookSurvey.new(book: books_books(:war_and_peace), classification: :coherent, surveyed_at: Time.current)

      assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
    end

    test "deleting the book deletes its survey" do
      book = Books::Book.create!(title: "A Bare Book")
      survey = RebuildBookSurvey.create!(book: book, classification: :unsupported, surveyed_at: Time.current)
      book.delete

      refute RebuildBookSurvey.exists?(survey.id)
    end

    test "classification enum" do
      assert_equal %w[coherent lump unsupported], RebuildBookSurvey.classifications.keys
    end

    test "disagreement scopes" do
      assert_equal [books_rebuild_book_surveys(:lump_survey)], RebuildBookSurvey.title_disagrees.to_a
      assert_empty RebuildBookSurvey.authors_disagree
      books_rebuild_book_surveys(:coherent_survey).update!(authors_agree: false)
      assert_equal [books_rebuild_book_surveys(:coherent_survey)], RebuildBookSurvey.authors_disagree.to_a
    end
  end
end
