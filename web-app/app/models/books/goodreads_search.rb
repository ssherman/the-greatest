# == Schema Information
#
# Table name: books_goodreads_searches
#
#  id             :bigint           not null, primary key
#  fetched_at     :datetime         not null
#  http_status    :integer
#  outcome        :integer          not null
#  parser_version :integer
#  query          :string           not null
#  rows           :jsonb            not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
# Indexes
#
#  index_books_goodreads_searches_on_query  (query) UNIQUE
#
module Books
  # One cached Goodreads title search (enrichment spec §4.2), keyed by its
  # normalized query. The rows are the parsed result list, kept whole so the
  # enrichment step can re-filter without searching again; the HTML is gzipped
  # on the private service for a parser fix to re-read. Never served.
  class GoodreadsSearch < ApplicationRecord
    FRESH_FOR = 30.days

    enum :outcome, {found: 0, no_results: 1, blocked: 2, unparseable: 3}, prefix: true

    has_one_attached :html, service: :private_imports

    normalizes :query, with: ->(query) { query.to_s.downcase.squish }

    scope :fresh, -> { where(outcome: [:found, :no_results]).where("fetched_at > ?", FRESH_FOR.ago) }

    validates :query, presence: true, uniqueness: true
    validates :fetched_at, presence: true

    def candidate_rows
      rows.map { |row| ::Books::Goodreads::SearchPage::Row.new(**row.symbolize_keys) }
    end
  end
end
