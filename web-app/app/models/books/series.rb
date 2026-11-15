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
class Books::Series < ApplicationRecord
  include Describable

  extend FriendlyId

  friendly_id :title, use: [:slugged, :finders]

  belongs_to :representative_book, class_name: "Books::Book", optional: true
  belongs_to :merged_into, class_name: "Books::Series", optional: true

  has_many :series_books, -> { order(:position) }, class_name: "Books::SeriesBook", dependent: :destroy
  has_many :books, through: :series_books, class_name: "Books::Book"

  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy

  validates :title, presence: true

  before_validation :normalize_title

  scope :active, -> { where(deleted: false) }
  scope :merged, -> { where.not(merged_into_id: nil) }

  # The series a reader should use in place of this one: itself when live, its merge
  # target when merged into a live series, nil otherwise (junk-deleted, or the target
  # was deleted since).
  def canonical
    return self unless deleted?
    return nil if merged_into.nil? || merged_into.deleted?

    merged_into
  end

  def resolved_representative_book
    representative_book || series_books.first&.book
  end

  def as_indexed_json
    {title: title}
  end

  private

  def normalize_title
    self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
  end
end
