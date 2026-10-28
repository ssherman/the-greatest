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
# What the Goodreads rebuild's stage one survey found about one derived book
# (docs/features/goodreads-rebuild.md): its export editions grouped into
# works, and whether our title and authors agree with them. Scratch data the
# survey rewrites on a redo; increment 2b reads it to fix titles, authors and
# lumps.
class Books::RebuildBookSurvey < ApplicationRecord
  belongs_to :book, class_name: "Books::Book"

  enum :classification, {coherent: 0, lump: 1, unsupported: 2}

  validates :classification, :surveyed_at, presence: true

  scope :title_disagrees, -> { where(title_agrees: false) }
  scope :authors_disagree, -> { where(authors_agree: false) }
end
