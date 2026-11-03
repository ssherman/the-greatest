# frozen_string_literal: true

# Shared setup for the re-import apply handler tests: a fresh reader (default lists, no fixtures on the books
# under test), a legacy replay import, and verdict builders.
module GoodreadsReimportApplyHelper
  def setup_reader
    @user = User.create!(email: "reimport-#{SecureRandom.hex(4)}@example.com", role: :user, email_verified: false)
    @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete, source: :legacy_replay, created_at: Time.zone.local(2026, 9, 1, 12))
    @from = books_books(:war_and_peace)
    @to = books_books(:of_mice_and_men)
    UserListItem.where(listable: [@from, @to]).delete_all
    Review.where(reviewable: [@from, @to]).delete_all
    ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
    @n = 0
  end

  def list(type) = ::Books::UserList.find_by!(user: @user, list_type: type)

  def csv_row(**attributes)
    @n += 1
    edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 96_000 + @n + ::Books::GoodreadsEdition.count,
      signature: "apply-sig-#{@user.id}-#{@n}", title: "Apply #{@n}", primary_author: "A")
    @import.rows.create!({row_number: @n, goodreads_edition: edition, exclusive_shelf: "read"}.merge(attributes))
  end

  def row_verdict(row, action:, from: @from, to: @to, review: false, superseded_by: nil)
    ::Books::RepairVerdict.create!(kind: :reimport_row, subject_key: "reimport:row:#{row.import_id}:#{row.row_number}", decided_by: :rule, status: :approved,
      payload: {"import_id" => row.import_id, "row_number" => row.row_number, "user_id" => @user.id, "action" => action,
                "from_book_id" => from&.id, "to_book_id" => to.id, "review" => review, "superseded_by" => superseded_by})
  end

  def guess_verdict(item_type:, item_id:, from: @from, to: @to)
    ::Books::RepairVerdict.create!(kind: :reimport_guess, subject_key: "reimport:guess:#{item_type}:#{item_id}", decided_by: :rule, status: :approved,
      payload: {"item_type" => item_type, "item_id" => item_id, "user_id" => @user.id, "from_book_id" => from.id, "to_book_id" => to.id})
  end
end
