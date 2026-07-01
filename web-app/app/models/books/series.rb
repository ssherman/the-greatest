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
class Books::Series < ApplicationRecord
  include SearchIndexable

  extend FriendlyId
  friendly_id :title, use: [ :slugged, :finders ]

  belongs_to :representative_book, class_name: "Books::Book", optional: true

  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy

  validates :title, presence: true

  before_validation :normalize_title

  def as_indexed_json
    { title: title }
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end
end
