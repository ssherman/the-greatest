require "test_helper"

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
module Books
  class AuthorRelationshipTest < ActiveSupport::TestCase
    test "links a pseudonym to a person" do
      rel = books_author_relationships(:bachman_is_king)
      assert_equal books_authors(:bachman), rel.from_author
      assert_equal books_authors(:king), rel.to_author
      assert_predicate rel, :relation_type_pseudonym_of?
    end

    test "rejects self-reference" do
      rel = Books::AuthorRelationship.new(from_author: books_authors(:king), to_author: books_authors(:king), relation_type: :pseudonym_of)
      assert_not rel.valid?
      assert_includes rel.errors[:to_author_id], "cannot relate an author to itself"
    end

    test "is unique per from/to/type" do
      dup = Books::AuthorRelationship.new(from_author: books_authors(:bachman), to_author: books_authors(:king), relation_type: :pseudonym_of)
      assert_not dup.valid?
      assert_includes dup.errors[:from_author_id], "has already been taken"
    end
  end
end
