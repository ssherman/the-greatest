# == Schema Information
#
# Table name: books_repair_verdicts
#
#  id                 :bigint           not null, primary key
#  applied_at         :datetime
#  confidence         :integer
#  decided_by         :integer          not null
#  error              :text
#  kind               :integer          not null
#  payload            :jsonb            not null
#  reason             :text
#  reviewed_at        :datetime
#  status             :integer          default("proposed"), not null
#  subject_key        :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_chat_id         :bigint
#  decided_by_user_id :bigint
#
# Indexes
#
#  index_books_repair_verdicts_on_kind_and_subject_key  (kind,subject_key) UNIQUE
#  index_books_repair_verdicts_on_status_and_kind       (status,kind)
#
module Books
  # One finding of the legacy Goodreads replay and what was decided about it
  # (Goodreads import spec §12.7). Keyed only by preserved ids, with no
  # foreign keys, so it outlives the books truncation before launch: never
  # truncate this table. decided_by says who made the finding; an admin's
  # review is decided_by_user_id and reviewed_at.
  class RepairVerdict < ApplicationRecord
    enum :kind, {relink: 0, merge_books: 1, merge_authors: 2, strip_identifier: 3, mark_provisional: 4}
    enum :decided_by, {rule: 0, ai: 1, admin: 2}, prefix: true
    enum :status, {proposed: 0, approved: 1, rejected: 2}
    enum :confidence, {certain: 0, high: 1, medium: 2, low: 3}, prefix: true

    validates :subject_key, presence: true, uniqueness: {scope: :kind}

    scope :unapplied, -> { where(applied_at: nil) }
    scope :newest_first, -> { order(updated_at: :desc, id: :desc) }

    def reviewed?
      reviewed_at.present?
    end

    def book_ids
      ids = case kind
      when "relink" then [payload["from_book_id"], payload["to_book_id"]]
      when "merge_books" then [payload["source_id"], payload["target_id"]]
      when "strip_identifier", "mark_provisional" then [payload["book_id"]]
      else []
      end
      ids.compact
    end

    def author_ids
      merge_authors? ? [payload["source_id"], payload["target_id"]].compact : []
    end

    def summary
      case kind
      when "relink"
        "Move user #{payload["user_id"]}'s list items and review from book ##{payload["from_book_id"]} " \
          "to book ##{payload["to_book_id"]} (Goodreads #{payload["goodreads_book_id"]})"
      when "merge_books" then "Merge book ##{payload["source_id"]} into book ##{payload["target_id"]}"
      when "merge_authors" then "Merge author ##{payload["source_id"]} into author ##{payload["target_id"]}"
      when "strip_identifier"
        changes = [["remove", payload["remove"]], ["add", payload["add"]]].filter_map do |verb, pairs|
          "#{verb} #{Array(pairs).map { |type, value| "#{type} #{value}" }.join(", ")}" if Array(pairs).any?
        end
        "On book ##{payload["book_id"]}: #{changes.join("; ")}"
      when "mark_provisional" then "Mark book ##{payload["book_id"]} provisional (#{payload["reason"]})"
      end
    end
  end
end
