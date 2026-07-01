# == Schema Information
#
# Table name: books_editions
#
#  id               :bigint           not null, primary key
#  book_binding     :integer
#  edition_type     :integer          default("standard"), not null
#  metadata         :jsonb            not null
#  page_count       :integer
#  popularity       :integer
#  publication_year :integer
#  subtitle         :string
#  title            :string
#  volume_number    :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  book_id          :bigint           not null
#  language_id      :bigint
#
# Indexes
#
#  index_books_editions_on_book_id        (book_id)
#  index_books_editions_on_edition_type   (edition_type)
#  index_books_editions_on_language_id    (language_id)
#  index_books_editions_on_volume_number  (volume_number)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (language_id => languages.id)
#
class Books::Edition < ApplicationRecord
  enum :edition_type, { standard: 0, annotated: 1, illustrated: 2, critical: 3, abridged: 4, revised: 5 }, prefix: :edition_type
  enum :book_binding, { hardcover: 0, paperback: 1, mass_market: 2, ebook: 3, audiobook: 4, library_binding: 5, leather_bound: 6, other: 7 }, prefix: :book_binding

  belongs_to :book, class_name: "Books::Book"
  belongs_to :language, class_name: "Language", optional: true

  has_many :credits, as: :creditable, class_name: "Books::Credit", dependent: :destroy
  has_many :identifiers, as: :identifiable, dependent: :destroy
  has_many :images, as: :parent, dependent: :destroy
  has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"
  has_many :external_links, as: :parent, dependent: :destroy
  has_many :ai_chats, as: :parent, dependent: :destroy

  validates :book, presence: true
  validates :edition_type, presence: true

  scope :complete, -> { where(volume_number: nil) }
  scope :by_binding, ->(value) { where(book_binding: value) }
end
