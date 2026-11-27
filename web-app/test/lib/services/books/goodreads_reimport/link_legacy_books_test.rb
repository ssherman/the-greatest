require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class LinkLegacyBooksTest < ActiveSupport::TestCase
        include GoodreadsReimportApplyHelper

        setup do
          setup_reader
          @list = list(:read)
          @row = csv_row
          @gid = @row.goodreads_edition.goodreads_book_id
        end

        def on_list(book) = UserListItem.create!(user_list: @list, listable: book, position: 1)

        # Legacy's book_identifiers, injected: {goodreads book id string => [legacy book ids]}.
        def link(legacy = {})
          LinkLegacyBooks.call(user_ids: [@user.id], legacy_holders: ->(ids) { legacy.slice(*ids) })
        end

        test "links a row through legacy's identifier when our copy of the book lacks it" do
          on_list(@from)

          result = link(@gid.to_s => [@from.id])

          assert_equal @from.id, @row.reload.legacy_book_id
          assert_equal [1, 0], result.data.values_at(:linked, :unlinked)
        end

        test "links a row through our own identifier" do
          on_list(@from)
          ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: @gid.to_s)

          link

          assert_equal @from.id, @row.reload.legacy_book_id
        end

        test "links a row through our slug-form identifier" do
          on_list(@from)
          ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: "#{@gid}-some-title")

          link

          assert_equal @from.id, @row.reload.legacy_book_id
        end

        test "follows a merge of the legacy book" do
          on_list(@to)
          RecordRedirect.create!(item_type: "Books::Book", from_id: 999_001, to_id: @to.id)

          link(@gid.to_s => [999_001])

          assert_equal @to.id, @row.reload.legacy_book_id
        end

        test "leaves a row alone when no holder of the id is on the reader's lists" do
          result = link(@gid.to_s => [@from.id])

          assert_nil @row.reload.legacy_book_id
          assert_equal [0, 1], result.data.values_at(:linked, :unlinked)
        end

        test "picks the lowest id when the reader has several holders, as LegacyChoice does" do
          low, high = [@from, @to].sort_by(&:id)
          on_list(high)
          UserListItem.create!(user_list: list(:want_to_read), listable: low, position: 1)

          link(@gid.to_s => [high.id, low.id])

          assert_equal low.id, @row.reload.legacy_book_id
        end

        test "never overwrites a row that is already linked" do
          on_list(@from)
          @row.update_columns(legacy_book_id: @to.id)

          link(@gid.to_s => [@from.id])

          assert_equal @to.id, @row.reload.legacy_book_id
        end

        test "leaves rows an applied verdict already decided" do
          on_list(@from)
          row_verdict(@row, action: "add", from: nil).update!(applied_at: Time.current)

          result = link(@gid.to_s => [@from.id])

          assert_nil @row.reload.legacy_book_id
          assert_equal [0, 0], result.data.values_at(:linked, :unlinked)
        end

        test "leaves rows the old replay decided had no legacy choice" do
          on_list(@from)
          @row.update_columns(replay_finding: ::Books::GoodreadsImportRow.replay_findings.fetch("no_legacy_choice"))

          link(@gid.to_s => [@from.id])

          assert_nil @row.reload.legacy_book_id
        end

        test "follows a deleted mixed book's redirect, as the sync routes the reader's legacy entry" do
          on_list(@to)
          RecordRedirect.create!(item_type: "Books::Book", from_id: 999_002, to_id: @to.id)
          ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:999002", decided_by: :rule,
            status: :approved, applied_at: Time.current, payload: {"book_id" => 999_002, "redirect_written" => @to.id})

          link(@gid.to_s => [999_002])

          assert_equal @to.id, @row.reload.legacy_book_id
        end

        test "uses only the reader's own lists" do
          other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", role: :user, email_verified: false)
          UserListItem.create!(user_list: ::Books::UserList.find_by!(user: other, list_type: :read), listable: @from, position: 1)

          link(@gid.to_s => [@from.id])

          assert_nil @row.reload.legacy_book_id
        end

        test "user_ids_to_link names only readers with unlinked rows of complete replay imports" do
          linked_user = @user
          @row.update_columns(legacy_book_id: @from.id)
          setup_reader
          csv_row

          assert_includes LinkLegacyBooks.user_ids_to_link, @user.id
          refute_includes LinkLegacyBooks.user_ids_to_link, linked_user.id
        end
      end
    end
  end
end
