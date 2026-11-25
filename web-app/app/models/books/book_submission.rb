# == Schema Information
#
# Table name: books_book_submissions
#
#  id                    :bigint           not null, primary key
#  announced_at          :datetime
#  asin                  :string
#  attempts              :integer          default(0), not null
#  blocked_fetches       :integer          default(0), not null
#  created_book          :boolean          default(FALSE), not null
#  dismissed_at          :datetime
#  error                 :text
#  fetch_errors          :integer          default(0), not null
#  fingerprint           :string
#  input_method          :integer          not null
#  isbn10                :string
#  isbn13                :string
#  lease_expires_at      :datetime
#  lease_token           :string
#  lookup                :jsonb
#  next_attempt_at       :datetime
#  processing_started_at :datetime
#  raw_input             :text
#  resolved_author_names :jsonb
#  resolved_title        :string
#  review_note           :text
#  review_sources        :jsonb
#  review_status         :integer          default("not_needed"), not null
#  reviewed_at           :datetime
#  reviewed_via          :integer
#  signature             :string
#  status                :integer          default("queued"), not null
#  supplied              :jsonb
#  sweeps                :integer          default(0), not null
#  typed_author_names    :jsonb
#  typed_title           :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  book_id               :bigint
#  claimed_by_id         :bigint
#  goodreads_book_id     :bigint
#  match_decision_id     :bigint
#  reviewed_by_id        :bigint
#  user_id               :bigint
#  user_list_id          :bigint
#  user_list_item_id     :bigint
#
# Indexes
#
#  index_books_book_submissions_on_book_id                   (book_id)
#  index_books_book_submissions_on_claimed_by_id             (claimed_by_id)
#  index_books_book_submissions_on_match_decision_id         (match_decision_id)
#  index_books_book_submissions_on_reviewed_by_id            (reviewed_by_id)
#  index_books_book_submissions_on_signature                 (signature)
#  index_books_book_submissions_on_status_and_review_status  (status,review_status)
#  index_books_book_submissions_on_user_id_and_created_at    (user_id,created_at)
#  index_books_book_submissions_on_user_list_id              (user_list_id)
#  index_books_book_submissions_on_user_list_item_id         (user_list_item_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id) ON DELETE => nullify
#  fk_rails_...  (claimed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (match_decision_id => match_decisions.id) ON DELETE => nullify
#  fk_rails_...  (reviewed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#  fk_rails_...  (user_list_id => user_lists.id) ON DELETE => nullify
#  fk_rails_...  (user_list_item_id => user_list_items.id) ON DELETE => nullify
#
module Books
  class BookSubmission < ApplicationRecord
    # Every foreign key nulls on delete, so the row outlives whoever or
    # whatever it points at.
    belongs_to :user, optional: true
    belongs_to :user_list, optional: true
    belongs_to :book, class_name: "::Books::Book", optional: true
    belongs_to :match_decision, optional: true
    belongs_to :user_list_item, optional: true
    belongs_to :reviewed_by, class_name: "::User", optional: true
    belongs_to :claimed_by, class_name: "::User", optional: true

    enum :input_method, {goodreads: 0, amazon: 1, isbn: 2, title_authors: 3}, prefix: :method
    enum :status, {queued: 0, looking_up: 1, needs_details: 2, added: 3, failed: 4, cancelled: 5}
    enum :review_status, {not_needed: 0, pending: 1, approved: 2, merged: 3, rejected: 4, needs_human: 5}, prefix: :review
    enum :reviewed_via, {api: 0, admin_ui: 1, system: 2}, prefix: true

    OPEN_STATUSES = %w[queued looking_up needs_details].freeze
    IN_PROGRESS_STATUSES = %w[queued looking_up].freeze
    MAX_AUTHORS = 10
    MAX_LENGTH = 255

    # The identifier columns each input method may carry. An Amazon ASIN can
    # be an ISBN-10, so amazon takes the ISBNs beside its ASIN.
    IDENTIFIER_COLUMNS = %i[goodreads_book_id asin isbn13 isbn10].freeze
    ALLOWED_IDENTIFIERS = {
      "goodreads" => %i[goodreads_book_id],
      "amazon" => %i[asin isbn13 isbn10],
      "isbn" => %i[isbn13 isbn10],
      "title_authors" => []
    }.freeze

    scope :open, -> { where(status: OPEN_STATUSES) }
    scope :visible, -> { where(dismissed_at: nil) }
    # What an admin or agent has to look at: a new book awaiting review, or a
    # request the lookup could not finish. A row flagged needs_human is taken
    # out of the agent queue and never comes back here, and neither is one an
    # admin, a merge, a promotion or a delete has closed (approved, merged,
    # rejected), whatever its status.
    scope :reviewable, -> {
      where(status: :added, review_status: :pending)
        .or(where(review_status: %i[not_needed pending], status: %i[needs_details failed]))
    }
    scope :claimable, -> { reviewable.where("lease_expires_at IS NULL OR lease_expires_at <= ?", Time.current) }

    validate :carries_only_its_own_input
    validate :title_and_authors_are_usable, if: :method_title_authors?

    def in_progress?
      IN_PROGRESS_STATUSES.include?(status)
    end

    def label
      resolved_title.presence || typed_title.presence || raw_input
    end

    # A book this request created that nobody has merged away or rejected.
    def user_added?
      created_book? && !review_merged? && !review_rejected?
    end

    private

    def carries_only_its_own_input
      return if input_method.blank?

      allowed = ALLOWED_IDENTIFIERS.fetch(input_method)
      (IDENTIFIER_COLUMNS - allowed).each do |column|
        errors.add(column, "does not belong with this input method") if self[column].present?
      end
      carries_typed = typed_title.present? || typed_author_names.present?
      if !method_title_authors? && carries_typed
        errors.add(:typed_title, "belongs only to a title and authors request")
      end
      errors.add(:raw_input, "does not belong with a title and authors request") if method_title_authors? && raw_input.present?
      required = {"goodreads" => :goodreads_book_id, "amazon" => :asin}[input_method]
      errors.add(required, "can't be blank") if required && self[required].blank?
      errors.add(:isbn13, "or isbn10 is required") if method_isbn? && isbn13.blank? && isbn10.blank?
    end

    def title_and_authors_are_usable
      errors.add(:typed_title, "can't be blank") if typed_title.blank?
      errors.add(:typed_title, "is too long") if typed_title.to_s.length > MAX_LENGTH
      names = Array(typed_author_names)
      errors.add(:typed_author_names, "needs at least one author") if names.empty?
      errors.add(:typed_author_names, "has too many authors") if names.size > MAX_AUTHORS
      if names.any? { |name| name.blank? || name.to_s.length > MAX_LENGTH }
        errors.add(:typed_author_names, "has a blank or too long name")
      end
    end
  end
end
