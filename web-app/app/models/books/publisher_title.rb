# == Schema Information
#
# Table name: books_publisher_titles
#
#  id              :bigint           not null, primary key
#  age_range       :string
#  contributors    :jsonb            not null
#  cover_url       :string
#  description     :text
#  first_read_at   :datetime
#  formats         :jsonb            not null
#  genres          :jsonb            not null
#  hold_reason     :integer
#  imprint_name    :string
#  isbn13s         :string           default([]), not null, is an Array
#  language        :string
#  last_read_at    :datetime
#  on_sale_on      :date
#  parser_version  :integer
#  publisher_name  :string
#  series_name     :string
#  series_position :string
#  source          :string           not null
#  source_key      :string
#  status          :integer          default("ready"), not null
#  subtitle        :string
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_books_publisher_titles_on_isbn13s                (isbn13s) USING gin
#  index_books_publisher_titles_on_on_sale_on             (on_sale_on)
#  index_books_publisher_titles_on_source_and_source_key  (source,source_key) UNIQUE WHERE (source_key IS NOT NULL)
#  index_books_publisher_titles_on_source_and_status      (source,status)
#
module Books
  # One title as one publisher describes it, with all its formats (publisher
  # intake design §1). Listings for each format's page point here. Enums are
  # prefixed because `set` is a hold reason.
  class PublisherTitle < ApplicationRecord
    enum :status, {ready: 0, held: 1}, prefix: true
    enum :hold_reason, {incomplete: 0, placeholder: 1, non_english: 2, not_a_book: 3, set: 4}, prefix: true

    has_many :listings, class_name: "Books::PublisherListing", foreign_key: :publisher_title_id,
      inverse_of: :publisher_title, dependent: :nullify

    scope :upcoming_first, -> { order(Arel.sql("on_sale_on IS NULL, on_sale_on ASC, id ASC")) }

    validates :source, presence: true
    validates :hold_reason, presence: true, if: :status_held?
    validates :hold_reason, absence: true, if: :status_ready?
  end
end
