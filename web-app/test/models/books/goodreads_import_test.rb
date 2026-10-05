require "test_helper"

# == Schema Information
#
# Table name: books_goodreads_imports
#
#  id               :bigint           not null, primary key
#  ai_calls_count   :integer          default(0), not null
#  created_count    :integer          default(0), not null
#  editions_count   :integer          default(0), not null
#  error            :text
#  finished_at      :datetime
#  flagged_count    :integer          default(0), not null
#  matched_count    :integer          default(0), not null
#  parked_count     :integer          default(0), not null
#  review_status    :integer          default("pending"), not null
#  reviewed_at      :datetime
#  rows_count       :integer          default(0), not null
#  skipped_count    :integer          default(0), not null
#  source           :integer          default("member"), not null
#  started_at       :datetime
#  status           :integer          default("queued"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  legacy_import_id :integer
#  reviewed_by_id   :bigint
#  user_id          :bigint           not null
#
# Indexes
#
#  index_books_goodreads_imports_on_legacy_import_id       (legacy_import_id) UNIQUE WHERE (legacy_import_id IS NOT NULL)
#  index_books_goodreads_imports_on_reviewed_by_id         (reviewed_by_id)
#  index_books_goodreads_imports_on_user_id                (user_id)
#  index_books_goodreads_imports_one_in_progress_per_user  (user_id) UNIQUE WHERE (status = ANY (ARRAY[0, 1, 2, 3, 4]))
#
# Foreign Keys
#
#  fk_rails_...  (reviewed_by_id => users.id)
#  fk_rails_...  (user_id => users.id)
#
module Books
  class GoodreadsImportTest < ActiveSupport::TestCase
    test "a user has at most one import in progress" do
      user = users(:editor_user)
      GoodreadsImport.create!(user: user, status: :queued)

      assert_raises(ActiveRecord::RecordNotUnique) { GoodreadsImport.create!(user: user, status: :resolving) }
    end

    test "a finished import does not block a new one" do
      assert books_goodreads_imports(:regular_user_import).complete?

      assert GoodreadsImport.create!(user: users(:regular_user), status: :queued).persisted?
    end

    test "a legacy import id is replayed into one import only" do
      GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: 42)

      assert_not GoodreadsImport.new(user: users(:editor_user), source: :legacy_replay, legacy_import_id: 42).valid?
    end

    test "editions lists an edition once however many rows name it" do
      import = books_goodreads_imports(:regular_user_import)
      import.rows.create!(row_number: 2, goodreads_edition: books_goodreads_editions(:war_and_peace_edition))

      assert_equal [books_goodreads_editions(:war_and_peace_edition)], import.editions.to_a
    end

    test "destroying the user takes the import, its rows and its provenance" do
      user = User.create!(email: "importer@example.com", role: :user, email_verified: false)
      import = GoodreadsImport.create!(user: user, status: :complete)
      import.rows.create!(row_number: 1)
      import.records.create!(record: books_books(:war_and_peace), action: :created)

      user.destroy!

      assert_equal [0, 0, 0], [GoodreadsImport.where(id: import.id).count,
        GoodreadsImportRow.where(import_id: import.id).count, GoodreadsImportRecord.where(import_id: import.id).count]
    end

    test "deleting an import leaves the editions it was waiting on, with nobody waiting" do
      import = GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
      edition = books_goodreads_editions(:unresolved_edition)
      edition.update!(verification: :pending, pending_import: import)

      import.destroy!

      assert_nil edition.reload.pending_import_id
      assert edition.verification_pending?
    end

    test "keeps the upload on the private imports service" do
      assert_equal :private_imports, Books::GoodreadsImport.reflect_on_attachment(:file).options[:service_name]
    end
  end
end
