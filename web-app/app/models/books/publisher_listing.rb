# == Schema Information
#
# Table name: books_publisher_listings
#
#  id                   :bigint           not null, primary key
#  attempts             :integer          default(0), not null
#  external_key         :string
#  first_seen_at        :datetime         not null
#  http_status          :integer
#  last_attempt_at      :datetime
#  last_attempt_outcome :integer
#  last_seen_at         :datetime         not null
#  outcome              :integer
#  parser_version       :integer
#  queued_at            :datetime
#  read_at              :datetime
#  signal               :string
#  source               :string           not null
#  state                :integer          default("pending"), not null
#  url                  :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  publisher_title_id   :bigint
#
# Indexes
#
#  index_books_publisher_listings_on_publisher_title_id       (publisher_title_id)
#  index_books_publisher_listings_on_source_and_external_key  (source,external_key)
#  index_books_publisher_listings_on_source_and_state         (source,state)
#  index_books_publisher_listings_on_source_and_url           (source,url) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (publisher_title_id => books_publisher_titles.id) ON DELETE => nullify
#
module Books
  # One URL a publisher's discovery source gave us (publisher intake design §1).
  # The page as fetched is kept gzipped on the private_imports service and is
  # never served. state, outcome and last_attempt_outcome are separate on
  # purpose: the last attempt can fail (unavailable, fetcher_down) while the
  # stored page's outcome stays what it was. Every enum is prefixed because
  # `read` is an Active Record method name.
  class PublisherListing < ApplicationRecord
    enum :state, {baseline: 0, pending: 1, read: 2, covered: 3, failed: 4}, prefix: true
    enum :outcome, {found: 0, not_found: 1, blocked: 2, unparseable: 3}, prefix: true
    enum :last_attempt_outcome,
      {found: 0, not_found: 1, blocked: 2, unparseable: 3, unavailable: 4, fetcher_down: 5},
      prefix: :last_attempt

    belongs_to :publisher_title, class_name: "Books::PublisherTitle", optional: true

    has_one_attached :html, service: :private_imports

    validates :source, presence: true
    validates :url, presence: true, uniqueness: {scope: :source}
  end
end
