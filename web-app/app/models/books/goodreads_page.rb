# == Schema Information
#
# Table name: books_goodreads_pages
#
#  id                        :bigint           not null, primary key
#  asin                      :string
#  authors                   :jsonb            not null
#  fetched_at                :datetime         not null
#  http_status               :integer
#  isbn10                    :string
#  isbn13                    :string
#  original_publication_year :integer
#  outcome                   :integer          not null
#  parser_version            :integer
#  series                    :jsonb            not null
#  source                    :integer          default("fetched"), not null
#  title                     :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  goodreads_book_id         :bigint           not null
#
# Indexes
#
#  index_books_goodreads_pages_on_goodreads_book_id  (goodreads_book_id) UNIQUE
#
module Books
  # One Goodreads book page by Goodreads id: the verification cache every
  # import shares (Goodreads import spec §3, §6). One fetch per id: a found or
  # not-found page is the answer from then on. A blocked or unparseable page
  # is kept, with its HTML, for a later look, and is fetched again. Legacy
  # rows (source: legacy) carry the legacy app's scraped facts and no HTML.
  #
  # The HTML is gzipped on the private_imports service, so a parser fix can
  # re-read it without fetching again. It is never served.
  class GoodreadsPage < ApplicationRecord
    enum :source, {fetched: 0, legacy: 1}
    enum :outcome, {found: 0, not_found: 1, blocked: 2, unparseable: 3}, prefix: true

    has_one_attached :html, service: :private_imports

    scope :conclusive, -> { where(outcome: [:found, :not_found]) }

    validates :goodreads_book_id, presence: true, uniqueness: true
    validates :fetched_at, presence: true

    def conclusive?
      outcome_found? || outcome_not_found?
    end
  end
end
