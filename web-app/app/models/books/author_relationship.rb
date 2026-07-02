# == Schema Information
#
# Table name: books_author_relationships
#
#  id             :bigint           not null, primary key
#  relation_type  :integer          default("pseudonym_of"), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  from_author_id :bigint           not null
#  to_author_id   :bigint           not null
#
# Indexes
#
#  index_books_author_relationships_on_from_author_id  (from_author_id)
#  index_books_author_relationships_on_to_author_id    (to_author_id)
#  index_books_author_relationships_unique             (from_author_id,to_author_id,relation_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (from_author_id => books_authors.id)
#  fk_rails_...  (to_author_id => books_authors.id)
#
class Books::AuthorRelationship < ApplicationRecord
  enum :relation_type, {pseudonym_of: 0, member_of: 1}, prefix: true

  belongs_to :from_author, class_name: "Books::Author"
  belongs_to :to_author, class_name: "Books::Author"

  validates :from_author_id, uniqueness: {scope: [:to_author_id, :relation_type]}
  validate :no_self_reference

  private

  def no_self_reference
    errors.add(:to_author_id, "cannot relate an author to itself") if from_author_id == to_author_id
  end
end
