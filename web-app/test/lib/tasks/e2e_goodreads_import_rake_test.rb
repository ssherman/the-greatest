# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eGoodreadsImportRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("e2e:goodreads_import_seed")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    Rake::Task["e2e:goodreads_import_seed"].reenable
    Rake::Task["e2e:goodreads_import_cleanup"].reenable
    @user = User.create!(email: "e2e-goodreads@example.com", role: :user, email_verified: false)
    ENV["E2E_GOODREADS_EMAIL"] = @user.email
  end

  teardown do
    ENV.delete("E2E_GOODREADS_EMAIL")
  end

  def seed_records
    edition_ids = Books::GoodreadsEdition.where(goodreads_book_id: GOODREADS_SEED_ID).pluck(:id)
    [
      Books::GoodreadsImport.where(id: Books::GoodreadsImportRow.where(goodreads_edition_id: edition_ids).select(:import_id)).count,
      edition_ids.size,
      Books::Book.where(title: GOODREADS_SEED_TITLE).count,
      Books::Author.where(name: GOODREADS_SEED_AUTHOR).count
    ]
  end

  test "seeds one finished import with one provisional book, idempotently, and cleans up every import naming it" do
    out, = capture_io { Rake::Task["e2e:goodreads_import_seed"].invoke }
    Rake::Task["e2e:goodreads_import_seed"].reenable
    capture_io { Rake::Task["e2e:goodreads_import_seed"].invoke }

    import = Books::GoodreadsImport.find(JSON.parse(out.lines.last)["import_id"])
    assert_equal [@user.id, "complete", "pending"], [import.user_id, import.status, import.review_status]
    assert Books::Book.find_by!(title: GOODREADS_SEED_TITLE).provisional?
    assert_equal [1, 1, 1, 1], seed_records

    # An upload of the E2E fixture lands on the same edition.
    upload = @user.goodreads_imports.create!(status: :queued)
    upload.rows.create!(row_number: 1, goodreads_edition: Books::GoodreadsEdition.find_by!(goodreads_book_id: GOODREADS_SEED_ID))

    capture_io { Rake::Task["e2e:goodreads_import_cleanup"].invoke }

    assert_equal [0, 0, 0, 0], seed_records
    assert Books::GoodreadsImport.exists?(books_goodreads_imports(:regular_user_import).id)
  end

  test "cleanup also removes an upload of the fixture that no worker ever parsed" do
    queued = @user.goodreads_imports.create!(status: :queued)
    queued.file.attach(io: StringIO.new("Book Id\n"), filename: "goodreads_export.csv", content_type: "text/csv", identify: false)
    other = @user.goodreads_imports.create!(status: :complete)
    other.file.attach(io: StringIO.new("Book Id\n"), filename: "my_real_export.csv", content_type: "text/csv", identify: false)

    capture_io { Rake::Task["e2e:goodreads_import_cleanup"].invoke }

    assert_not Books::GoodreadsImport.exists?(queued.id)
    assert Books::GoodreadsImport.exists?(other.id)
  end
end
