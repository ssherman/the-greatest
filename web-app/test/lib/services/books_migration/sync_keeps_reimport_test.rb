require "test_helper"

# The acceptance test for spec 2026-11-26-books-sync-keeps-reimport: the REAL re-import apply runs first, then
# the REAL sync steps run over legacy rows that still show what the old importer guessed. Nothing the re-import
# changed may revert, while an unrelated legacy edit by the same reader still syncs.
class Services::BooksMigration::SyncKeepsReimportTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include GoodreadsReimportApplyHelper
  include SequenceIsolation

  isolate_sequences "reviews"

  T = Time.utc(2025, 1, 1)

  setup do
    ::Review.delete_all
    ::ReviewSummary.delete_all
    setup_reader
    # @from (war_and_peace) and @to (of_mice_and_men) are the move; @added is an add; @copy_from -> @copy_to a copy.
    @added = ::Books::Book.create!(title: "Added")
    @copy_from = ::Books::Book.create!(title: "Copy from")
    @copy_to = ::Books::Book.create!(title: "Copy to")
    @shelved = ::Books::Book.create!(title: "Shelved elsewhere")
    @fresh = ::Books::Book.create!(title: "Reviewed only on legacy")
    @removed = ::Books::Book.create!(title: "Removed on legacy")
    @mixed = ::Books::Book.create!(title: "Mixed Lump", book_kind: :standalone)
    @mixed_to = ::Books::Book.create!(title: "Mixed destination")
    # Legacy-origin lists (ids below the ceiling) and review; the sync ignores the default lists User.create! made.
    @shelf = ::Books::UserList.create!(id: 600, user: @user, name: "Legacy list", list_type: :custom)
    @other_shelf = ::Books::UserList.create!(id: 601, user: @user, name: "Second legacy list", list_type: :custom)
    # The reader's default Read list is legacy-origin too, as in production: the apply writes the add and the copy to it.
    list(:read).destroy!
    @read = ::Books::UserList.create!(id: 602, user: @user, name: "Read", list_type: :read)
    [@from, @copy_from, @shelved, @mixed, @removed].each_with_index do |book, index|
      UserListItem.create!(user_list: @shelf, listable: book, position: index + 1)
    end
    @review = ::Review.create!(id: 700, user: @user, reviewable: @from, rating: 3)
  end

  def legacy_item(id, list, book, position)
    {"id" => id, "user_list_id" => list.id, "book_id" => book.id, "position" => position, "read_date" => nil,
     "created_at" => T, "updated_at" => T}
  end

  def legacy_review(id, book, rating)
    {"id" => id, "user_id" => @user.id, "book_id" => book.id, "title" => nil, "body" => nil, "rating" => rating,
     "created_at" => T, "updated_at" => T}
  end

  def apply(verdict)
    result = Services::Books::GoodreadsReimport::Apply::Row.call(verdict: verdict)
    assert_equal :applied, result.data[:outcome], result.data.inspect
    # ApplyVerdicts stamps applied_at after the handler returns; Mixed and the sweeps read it.
    verdict.reload.tap { |applied| applied.update!(applied_at: Time.current) }
  end

  def migrate(scope, items, reviews)
    items_migrator = Services::BooksMigration::UserListItemMigrator.new(sync: scope)
    items_migrator.define_singleton_method(:legacy_items_for) { |ids| items.select { |row| ids.include?(row["user_list_id"]) } }
    items_migrator.define_singleton_method(:legacy_item_count) { items.size }
    review_migrator = Services::BooksMigration::ReviewMigrator.new(sync: scope)
    review_migrator.stubs(:legacy_each).multiple_yields(*reviews.zip)
    [items_migrator.call, review_migrator.call]
  end

  def reimport_hold(redirects) = Services::BooksMigration::ReimportHold.load(redirects: redirects)

  test "an applied re-import survives the sync while an unrelated legacy edit still syncs" do
    move = apply(row_verdict(csv_row(rating: 4.5), action: "move", review: true))
    add = apply(row_verdict(csv_row, action: "add", from: nil, to: @added))
    copy = apply(row_verdict(csv_row, action: "copy", from: @copy_from, to: @copy_to))
    # A mixed book: the reader's row is copied to @mixed_to, then the real Mixed handler deletes it, recording M -> T.
    mixed = ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{@mixed.id}", decided_by: :rule,
      status: :approved, payload: {"book_id" => @mixed.id, "redirect_to_book_id" => @mixed_to.id, "archive" => {}})
    mixed_copy = apply(row_verdict(csv_row, action: "copy", from: @mixed, to: @mixed_to))
    mixed_result = Services::Books::GoodreadsReimport::Apply::Mixed.call(verdict: mixed)
    assert_equal :applied, mixed_result.data[:outcome], mixed_result.data.inspect
    assert_not ::Books::Book.exists?(@mixed.id)
    assert_equal 1, mixed.reload.payload["deleted"].size
    verdicts = [move, add, copy, mixed_copy]
    assert_equal [@to.id, 4.5], [@review.reload.reviewable_id, @review.rating.to_f]
    assert UserListItem.exists?(user_list: @shelf, listable: @to)
    assert_not UserListItem.exists?(user_list: @shelf, listable: @copy_from), "the apply's leftover sweep removed the original"

    # Legacy still shows the pre-apply state, plus one unrelated shelf move, one unrelated deletion (@removed is gone
    # from every legacy list) and one new review by the same reader. Legacy still names the deleted mixed book, on the second list only: a sync without the hold would route it
    # to its destination there and drop the destination the copy put on the first list.
    items = [legacy_item(1, @shelf, @from, 1), legacy_item(2, @shelf, @copy_from, 2), legacy_item(3, @other_shelf, @shelved, 1),
      legacy_item(4, @other_shelf, @mixed, 2)]
    reviews = [legacy_review(701, @fresh, 5), legacy_review(700, @from, 3)]
    legacy = FakeLegacySource.new(
      user_list_versions: {600 => T, 601 => T, 602 => T}, user_list_items: items,
      user_list_owners: {600 => @user.id, 601 => @user.id, 602 => @user.id},
      review_rows: reviews.map { |row| row.values_at("id", "user_id", "book_id", "updated_at") }
    )
    redirects = [["Books::Book", @mixed.id, @mixed_to.id]]
    scope = sync_scope(redirects: redirects, hold: reimport_hold(Services::BooksMigration::Redirects.new(redirects)))

    # The report, computed first on the same data, must agree with what the run then does.
    diff = Services::BooksMigration::UserDataDiff.call(scope: scope, legacy: legacy)
    item_result, review_result = migrate(scope, items, reviews)

    assert item_result[:success], item_result[:error]
    assert review_result[:success], review_result[:error]
    item_keys = [:inserted, :deleted, :held_legacy, :held_here]
    assert_equal diff[:user_list_items].slice(*item_keys), item_result[:data].slice(*item_keys)
    assert_equal diff[:reviews].slice(:inserted, :deleted, :held), review_result[:data].slice(:inserted, :deleted, :held)
    assert_equal [1, 2], item_result[:data].values_at(:inserted, :deleted), "only the unrelated shelf move (1 in, 1 out) and removal (1 out) sync"

    # Everything the re-import recorded is still where it put it.
    verdicts.each do |verdict|
      moved = verdict.payload["moved"]
      moved["list_item_ids_after"].each do |id|
        assert_equal verdict.payload["to_book_id"], UserListItem.find(id).listable_id
      end
      if moved["review_id_after"]
        assert_equal verdict.payload["to_book_id"], ::Review.find(moved["review_id_after"]).reviewable_id
      end
    end
    assert_equal [@to.id, 4.5], [@review.reload.reviewable_id, @review.rating.to_f]
    assert_empty UserListItem.where(listable_id: @from.id, user_list_id: [@shelf.id, @other_shelf.id, @read.id])
    assert_empty ::Review.where(reviewable_id: @from.id)
    assert UserListItem.exists?(user_list: @shelf, listable: @to)
    assert UserListItem.exists?(user_list: @shelf, listable: @copy_to)
    assert UserListItem.exists?(user_list: @read, listable: @added), "the add"
    assert UserListItem.exists?(user_list: @read, listable: @copy_to), "the copy's Read item"
    assert UserListItem.exists?(user_list: @shelf, listable: @mixed_to), "the mixed copy's destination"
    assert_not UserListItem.exists?(user_list: @shelf, listable: @copy_from), "the swept original stays gone"
    # The deleted mixed book comes back neither as itself nor as its destination on the list the reader never had it on.
    assert_empty UserListItem.where(listable_type: "Books::Book", listable_id: @mixed.id)
    assert_not UserListItem.exists?(user_list: @other_shelf, listable: @mixed_to), "legacy's mixed-book row stays held"

    # The unrelated legacy edits came over.
    assert_equal [@other_shelf.id], UserListItem.where(listable_id: @shelved.id, user_list_id: [@shelf.id, @other_shelf.id]).pluck(:user_list_id)
    assert_not UserListItem.exists?(user_list: @shelf, listable: @removed), "the unrelated legacy deletion"
    assert_equal @fresh.id, ::Review.find(701).reviewable_id

    # And the report now has nothing left to do.
    after = Services::BooksMigration::UserDataDiff.call(scope: scope, legacy: legacy)
    assert_equal [0, 0], after[:user_list_items].values_at(:inserted, :deleted)
    assert_equal [0, 0, 0], after[:reviews].values_at(:inserted, :deleted, :updated)
  end
end
