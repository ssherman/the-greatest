# == Schema Information
#
# Table name: books_authors
#
#  id              :bigint           not null, primary key
#  alternate_names :string           default([]), not null, is an Array
#  birth_year      :integer
#  death_year      :integer
#  description     :text
#  kind            :integer          default("person"), not null
#  name            :string           not null
#  slug            :string           not null
#  sort_name       :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_books_authors_on_alternate_names  (alternate_names) USING gin
#  index_books_authors_on_kind             (kind)
#  index_books_authors_on_slug             (slug) UNIQUE
#
class Books::Author < ApplicationRecord
  extend FriendlyId
  friendly_id :name, use: [ :slugged, :finders ]

  enum :kind, { person: 0, organization: 1, pseudonym: 2, collective: 3 }

  has_many :author_relationships, class_name: "Books::AuthorRelationship", foreign_key: :from_author_id, dependent: :destroy
  has_many :inverse_author_relationships, class_name: "Books::AuthorRelationship", foreign_key: :to_author_id, dependent: :destroy
  has_many :credits, class_name: "Books::Credit", dependent: :destroy
  has_many :book_authors, class_name: "Books::BookAuthor", dependent: :destroy
  has_many :books, through: :book_authors, class_name: "Books::Book"
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Books::Category"
  has_many :ranked_items, as: :item, dependent: :destroy

  validates :name, presence: true
  validates :kind, presence: true

  before_validation :normalize_name

  def as_indexed_json
    {
      name: name,
      alternate_names: alternate_names,
      category_ids: categories.active.pluck(:id)
    }
  end

  private

  def normalize_name
    self.name = Services::Text::QuoteNormalizer.call(name) if name.present?
  end
end
