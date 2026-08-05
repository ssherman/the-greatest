# == Schema Information
#
# Table name: books_countries
#
#  id          :bigint           not null, primary key
#  book_count  :integer          default(0), not null
#  description :text
#  labels      :string           default([]), not null, is an Array
#  name        :string           not null
#  slug        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_books_countries_on_book_count  (book_count)
#  index_books_countries_on_labels      (labels) USING gin
#  index_books_countries_on_slug        (slug) UNIQUE
#
module Books
  class Country < ApplicationRecord
    extend FriendlyId

    friendly_id :name, use: [:slugged, :finders]

    has_many :book_countries, class_name: "Books::BookCountry", dependent: :destroy
    has_many :books, through: :book_countries, class_name: "Books::Book"

    validates :name, presence: true

    scope :with_label, ->(label) { where("labels @> ARRAY[?]::varchar[]", label) }
    scope :without_label, ->(label) {
      where.not("labels @> ARRAY[?]::varchar[]", label).or(where(labels: []))
    }
    scope :sorted_by_name, -> { order(:name) }
    scope :filterable, -> { where.not(slug: "unknown") }
    scope :search_by_name, ->(name) { where("name ILIKE ?", "%" + sanitize_sql_like(name) + "%") }
  end
end
