# == Schema Information
#
# Table name: books_credits
#
#  id              :bigint           not null, primary key
#  creditable_type :string           not null
#  position        :integer
#  role            :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  author_id       :bigint           not null
#  creditable_id   :bigint           not null
#
# Indexes
#
#  index_books_credits_on_author_id           (author_id)
#  index_books_credits_on_author_id_and_role  (author_id,role)
#  index_books_credits_on_creditable          (creditable_type,creditable_id)
#
# Foreign Keys
#
#  fk_rails_...  (author_id => books_authors.id)
#
class Books::Credit < ApplicationRecord
  enum :role, { translator: 0, illustrator: 1, editor: 2, introduction: 3, foreword: 4, afterword: 5, narrator: 6, cover_artist: 7, contributor: 8, ghostwriter: 9 }

  belongs_to :author, class_name: "Books::Author"
  belongs_to :creditable, polymorphic: true

  validates :author, presence: true
  validates :creditable, presence: true
  validates :role, presence: true

  scope :by_role, ->(role) { where(role: role) }
  scope :ordered, -> { order(:position, :id) }
end
