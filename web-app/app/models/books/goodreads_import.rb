# == Schema Information
#
# Table name: books_goodreads_imports
#
#  id                        :bigint           not null, primary key
#  ai_calls_count            :integer          default(0), not null
#  created_count             :integer          default(0), not null
#  editions_count            :integer          default(0), not null
#  error                     :text
#  finished_at               :datetime
#  flagged_count             :integer          default(0), not null
#  matched_count             :integer          default(0), not null
#  parked_count              :integer          default(0), not null
#  review_status             :integer          default("pending"), not null
#  reviewed_at               :datetime
#  rows_count                :integer          default(0), not null
#  skipped_count             :integer          default(0), not null
#  source                    :integer          default("member"), not null
#  started_at                :datetime
#  status                    :integer          default("queued"), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  finishes_legacy_import_id :integer
#  legacy_import_id          :integer
#  reviewed_by_id            :bigint
#  user_id                   :bigint           not null
#
# Indexes
#
#  index_books_goodreads_imports_on_finishes_legacy_import_id  (finishes_legacy_import_id) UNIQUE WHERE (finishes_legacy_import_id IS NOT NULL)
#  index_books_goodreads_imports_on_legacy_import_id           (legacy_import_id) UNIQUE WHERE (legacy_import_id IS NOT NULL)
#  index_books_goodreads_imports_on_reviewed_by_id             (reviewed_by_id)
#  index_books_goodreads_imports_on_user_id                    (user_id)
#  index_books_goodreads_imports_one_in_progress_per_user      (user_id) UNIQUE WHERE (status = ANY (ARRAY[0, 1, 2, 3, 4]))
#
# Foreign Keys
#
#  fk_rails_...  (reviewed_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
module Books
  class GoodreadsImport < ApplicationRecord
    belongs_to :user
    belongs_to :reviewed_by, class_name: "User", optional: true
    has_many :rows, class_name: "Books::GoodreadsImportRow", foreign_key: :import_id, inverse_of: :import,
      dependent: :delete_all
    has_many :records, class_name: "Books::GoodreadsImportRecord", foreign_key: :import_id, inverse_of: :import,
      dependent: :delete_all
    has_many :editions, -> { distinct }, through: :rows, source: :goodreads_edition
    has_many :pending_editions, class_name: "Books::GoodreadsEdition", foreign_key: :pending_import_id,
      inverse_of: :pending_import, dependent: :nullify
    # The upload as received, Private Notes included, so it lives on the
    # private service only (spec §3). Rows store the parsed fields without it.
    has_one_attached :file, service: :private_imports

    enum :source, {member: 0, legacy_replay: 1}
    enum :status, {queued: 0, parsing: 1, resolving: 2, verifying: 3, writing: 4, complete: 5, failed: 6}
    enum :review_status, {pending: 0, approved: 1, rejected: 2}, prefix: :review

    # The statuses the one-in-progress-per-user index covers.
    IN_PROGRESS = %w[queued parsing resolving verifying writing].freeze

    scope :in_progress, -> { where(status: IN_PROGRESS) }

    validates :legacy_import_id, uniqueness: true, allow_nil: true
    validates :finishes_legacy_import_id, uniqueness: true, allow_nil: true

    def in_progress?
      IN_PROGRESS.include?(status)
    end

    def stuck?(now = Time.current)
      in_progress? && (started_at || created_at) < now - Rails.application.config.x.goodreads_imports.stuck_after
    end

    # Ids one key of every row's `applied` names: "list_item_ids" (arrays)
    # or "review_id".
    def applied_ids(key)
      rows.where("applied ? :key", key: key).pluck(Arel.sql("applied -> #{self.class.connection.quote(key)}"))
        .flat_map { |value| Array(value) }.map(&:to_i)
    end
  end
end
