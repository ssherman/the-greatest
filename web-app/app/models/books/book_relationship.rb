# == Schema Information
#
# Table name: books_book_relationships
#
#  id              :bigint           not null, primary key
#  relation_type   :integer          default("contains"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  book_id         :bigint           not null
#  related_book_id :bigint           not null
#
# Indexes
#
#  index_books_book_relationships_on_book_id          (book_id)
#  index_books_book_relationships_on_related_book_id  (related_book_id)
#  index_books_book_relationships_unique              (book_id,related_book_id,relation_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (related_book_id => books_books.id)
#
class Books::BookRelationship < ApplicationRecord
  enum :relation_type, {contains: 0, abridgement_of: 1, adaptation_of: 2, revision_of: 3, related_to: 4}, prefix: true

  belongs_to :book, class_name: "Books::Book"
  belongs_to :related_book, class_name: "Books::Book"

  validates :book_id, uniqueness: {scope: [:related_book_id, :relation_type]}
  validate :no_self_reference

  scope :containing, -> { where(relation_type: :contains) }

  private

  def no_self_reference
    errors.add(:related_book_id, "cannot relate a book to itself") if book_id == related_book_id
  end
end
