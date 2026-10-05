require "test_helper"

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
  class RepairVerdictTest < ActiveSupport::TestCase
    def verdict(**attributes)
      RepairVerdict.create!({kind: :relink, subject_key: "user:1:book:2:goodreads:3", decided_by: :ai,
        payload: {"user_id" => 1, "from_book_id" => 2, "to_book_id" => 4, "goodreads_book_id" => 3}}.merge(attributes))
    end

    test "subject keys are unique per kind, not across kinds" do
      verdict
      assert_raises(ActiveRecord::RecordInvalid) { verdict }
      assert_nothing_raised { verdict(kind: :strip_identifier) }
    end

    test "a new verdict is proposed and unreviewed" do
      record = verdict

      assert_predicate record, :proposed?
      refute_predicate record, :reviewed?
    end

    test "summary describes each kind in plain words" do
      assert_equal "Move user 1's list items and review from book #2 to book #4 (Goodreads 3)", verdict.summary
      assert_equal "Merge book #8 into book #9",
        verdict(kind: :merge_books, subject_key: "books:8:9", payload: {"source_id" => 8, "target_id" => 9}).summary
      assert_equal "Merge author #5 into author #6",
        verdict(kind: :merge_authors, subject_key: "authors:5:6", payload: {"source_id" => 5, "target_id" => 6}).summary
      assert_equal "On book #7: remove books_work_goodreads_id 12-slug; add books_work_goodreads_id 12",
        verdict(kind: :strip_identifier, subject_key: "book:7:books_work_goodreads_id:12-slug",
          payload: {"book_id" => 7, "remove" => [["books_work_goodreads_id", "12-slug"]], "add" => [["books_work_goodreads_id", "12"]]}).summary
      assert_equal "Mark book #7 provisional (authorless)",
        verdict(kind: :mark_provisional, subject_key: "book:7", payload: {"book_id" => 7, "reason" => "authorless"}).summary
    end

    test "unapplied excludes applied verdicts" do
      applied = verdict(applied_at: Time.current)
      pending = verdict(kind: :merge_books, subject_key: "books:1:2")

      assert_equal [pending.id], RepairVerdict.unapplied.where(id: [applied.id, pending.id]).pluck(:id)
    end

    test "names the books and authors each kind is about" do
      assert_equal [2, 4], verdict.book_ids
      assert_equal [8, 9], verdict(kind: :merge_books, subject_key: "books:8:9", payload: {"source_id" => 8, "target_id" => 9}).book_ids
      merge = verdict(kind: :merge_authors, subject_key: "authors:5:6", payload: {"source_id" => 5, "target_id" => 6})
      assert_equal [[], [5, 6]], [merge.book_ids, merge.author_ids]
      assert_equal [7], verdict(kind: :mark_provisional, subject_key: "book:7", payload: {"book_id" => 7}).book_ids
      assert_empty verdict(subject_key: "user:2:book:3:goodreads:4").author_ids
    end

    test "the replay never applies by default" do
      refute Rails.configuration.x.goodreads_replay.auto_apply
      assert_equal 80, Rails.configuration.x.goodreads_replay.max_author_group
    end
  end
end
