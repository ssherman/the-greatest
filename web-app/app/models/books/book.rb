# == Schema Information
#
# Table name: books_books
#
#  id                   :bigint           not null, primary key
#  alternate_titles     :string           default([]), not null, is an Array
#  book_kind            :integer          default("standalone"), not null
#  description          :text
#  first_published_year :integer
#  slug                 :string           not null
#  sort_title           :string
#  subtitle             :string
#  title                :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  default_edition_id   :bigint
#  original_language_id :bigint
#
# Indexes
#
#  index_books_books_on_alternate_titles      (alternate_titles) USING gin
#  index_books_books_on_book_kind             (book_kind)
#  index_books_books_on_default_edition_id    (default_edition_id)
#  index_books_books_on_first_published_year  (first_published_year)
#  index_books_books_on_original_language_id  (original_language_id)
#  index_books_books_on_slug                  (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (default_edition_id => books_editions.id) ON DELETE => nullify
#  fk_rails_...  (original_language_id => languages.id)
#
class Books::Book < ApplicationRecord
  extend FriendlyId

  friendly_id :title, use: [ :slugged, :finders ]

  enum :book_kind, { standalone: 0, collection: 1 }

  belongs_to :original_language, class_name: "Language", optional: true
  belongs_to :default_edition, class_name: "Books::Edition", optional: true
  has_many :book_authors, -> { order(:position) }, class_name: "Books::BookAuthor", dependent: :destroy
  has_many :authors, through: :book_authors, class_name: "Books::Author"
  has_many :editions, class_name: "Books::Edition", dependent: :destroy

  has_many :credits, as: :creditable, class_name: "Books::Credit", dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :category_items, as: :item, dependent: :destroy, inverse_of: :item
  has_many :categories, through: :category_items, class_name: "Books::Category"
  has_many :list_items, as: :listable, dependent: :destroy
  has_many :lists, through: :list_items
  has_many :user_list_items, as: :listable, dependent: :destroy
  has_many :user_lists, through: :user_list_items
  has_many :ranked_items, as: :item, dependent: :destroy
  has_many :series_books, class_name: "Books::SeriesBook", dependent: :destroy
  has_many :series, through: :series_books, class_name: "Books::Series"
  has_many :book_relationships, class_name: "Books::BookRelationship", dependent: :destroy
  has_many :related_books, through: :book_relationships, class_name: "Books::Book"
  has_many :inverse_book_relationships, class_name: "Books::BookRelationship", foreign_key: :related_book_id, dependent: :destroy

  validates :title, presence: true

  before_validation :normalize_title

  scope :selectable, -> { where(book_kind: :standalone) }

  def as_indexed_json
    {
      title: title,
      subtitle: subtitle,
      alternate_titles: alternate_titles,
      author_names: authors.map(&:name),
      author_ids: authors.map(&:id),
      category_ids: categories.active.pluck(:id),
      book_kind: book_kind
    }
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end
end
