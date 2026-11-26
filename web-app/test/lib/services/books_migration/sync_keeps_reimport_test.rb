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
    # Legacy-origin lists (ids below the ceiling) and review; the sync ignores the default lists User.create! made.
    @shelf = ::Books::UserList.create!(id: 600, user: @user, name: "Legacy list", list_type: :custom)
    @other_shelf = ::Books::UserList.create!(id: 601, user: @user, name: "Second legacy list", list_type: :custom)
    [@from, @copy_from, @shelved].each_with_index do |book, index|
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
    verdict.reload
  end

  test "an applied re-import survives the sync while an unrelated legacy edit still syncs" do
    move = apply(row_verdict(csv_row(rating: 4.5), action: "move", review: true))
    add = apply(row_verdict(csv_row, action: "add", from: nil, to: @added))
    copy = apply(row_verdict(csv_row, action: "copy", from: @copy_from, to: @copy_to))
    verdicts = [move, add, copy]
    assert_equal [@to.id, 4.5], [@review.reload.reviewable_id, @review.rating.to_f]
    assert UserListItem.exists?(user_list: @shelf, listable: @to)

    # Legacy still shows the pre-apply state, plus one unrelated shelf move and one new review by the same reader.
    items = [legacy_item(1, @shelf, @from, 1), legacy_item(2, @shelf, @copy_from, 2), legacy_item(3, @other_shelf, @shelved, 1)]
    reviews = [legacy_review(701, @fresh, 5), legacy_review(700, @from, 3)]
    legacy = FakeLegacySource.new(
      user_list_versions: {600 => T, 601 => T}, user_list_items: items, user_list_owners: {600 => @user.id, 601 => @user.id},
      review_rows: reviews.map { |row| row.values_at("id", "user_id", "book_id", "updated_at") }
    )
    hold = Services::BooksMigration::ReimportHold.load(redirects: Services::BooksMigration::Redirects.new([]))
    scope = sync_scope(hold: hold)

    items_migrator = Services::BooksMigration::UserListItemMigrator.new(sync: scope)
    items_migrator.define_singleton_method(:legacy_items_for) { |ids| items.select { |row| ids.include?(row["user_list_id"]) } }
    items_migrator.define_singleton_method(:legacy_item_count) { items.size }
    item_result = items_migrator.call
    review_migrator = Services::BooksMigration::ReviewMigrator.new(sync: scope)
    review_migrator.stubs(:legacy_each).multiple_yields(*reviews.zip)
    review_result = review_migrator.call

    assert item_result[:success], item_result[:error]
    assert review_result[:success], review_result[:error]

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
    assert_empty UserListItem.where(listable_id: @from.id, user_list_id: [@shelf.id, @other_shelf.id])
    assert_empty ::Review.where(reviewable_id: @from.id)
    assert UserListItem.exists?(user_list: @shelf, listable: @to)
    assert UserListItem.exists?(user_list: @shelf, listable: @copy_to)

    # The unrelated legacy edits came over.
    assert_equal [@other_shelf.id], UserListItem.where(listable_id: @shelved.id, user_list_id: [@shelf.id, @other_shelf.id]).pluck(:user_list_id)
    assert_equal @fresh.id, ::Review.find(701).reviewable_id

    # The report agrees with what the sync did: nothing left to insert, delete or update.
    diff = Services::BooksMigration::UserDataDiff.call(scope: scope, legacy: legacy)
    assert_equal [0, 0], diff[:user_list_items].values_at(:inserted, :deleted)
    assert_equal [0, 0, 0], diff[:reviews].values_at(:inserted, :deleted, :updated)
  end
end
