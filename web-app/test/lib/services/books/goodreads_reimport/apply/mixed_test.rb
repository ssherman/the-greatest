# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class MixedTest < ActiveSupport::TestCase
          include GoodreadsReimportApplyHelper
          include ActiveJob::TestHelper

          setup do
            setup_reader
            @mixed = ::Books::Book.create!(title: "Mixed Lump", book_kind: :standalone)
          end

          def mixed_verdict(redirect: @to.id, **attributes)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{@mixed.id}", decided_by: :rule,
              status: :approved, **attributes,
              payload: {"book_id" => @mixed.id, "redirect_to_book_id" => redirect, "archive" => {}})
          end

          def copy_verdict(user: @user, applied: true)
            row = csv_row
            verdict = row_verdict(row, action: "copy", from: @mixed)
            verdict.update!(payload: verdict.payload.merge("user_id" => user.id))
            verdict.update!(applied_at: Time.current) if applied
            verdict
          end

          test "a kept book keeps a Favorites item of a reader whose row heads to it, and removes the Read original" do
            kept = mixed_verdict
            kept.update!(payload: kept.payload.merge("kept" => true))
            fav = UserListItem.create!(user_list: list(:favorites), listable: @mixed)
            original = UserListItem.create!(user_list: list(:read), listable: @mixed)
            row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @mixed, to: @mixed).update!(applied_at: Time.current)
            row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @mixed, to: @to).update!(applied_at: Time.current)

            Mixed.call(verdict: kept)

            assert UserListItem.exists?(fav.id)
            assert_not UserListItem.exists?(original.id)
          end

          test "a kept mixed book is a final noop and deletes nothing, redirect or not" do
            verdict = mixed_verdict
            verdict.update!(payload: verdict.payload.merge("kept" => true))
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            result = Mixed.call(verdict: verdict)

            assert_equal [:noop, true, "kept: readers matched this book"], result.data.values_at(:outcome, :final, :reason)
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "a kept book ends with exactly what the rows heading to it say: the split user's leftover original goes, recorded" do
            kept = mixed_verdict
            kept.update!(payload: kept.payload.merge("kept" => true))
            original = UserListItem.create!(user_list: list(:read), listable: @mixed)
            row_a = csv_row(exclusive_shelf: "to-read")
            row_b = csv_row(exclusive_shelf: "read")
            verdict_a = row_verdict(row_a, action: "copy", from: @mixed, to: @mixed)
            verdict_b = row_verdict(row_b, action: "copy", from: @mixed, to: @to)
            bystander = User.create!(email: "by-#{SecureRandom.hex(3)}@example.com", role: :user, email_verified: false)
            bystander_item = UserListItem.create!(user_list: ::Books::UserList.find_by!(user: bystander, list_type: :read), listable: @mixed)

            # While the copy to the other book is unapplied, the original is still needed.
            assert Row.call(verdict: verdict_a).data[:outcome] == :applied
            verdict_a.update!(applied_at: Time.current)
            Row.call(verdict: verdict_b)
            verdict_b.update!(applied_at: nil)
            assert_equal [:noop, false], Mixed.call(verdict: kept).data.values_at(:outcome, :final)
            assert UserListItem.exists?(original.id)

            verdict_b.update!(applied_at: Time.current)
            result = Mixed.call(verdict: kept)

            assert_equal [:noop, true, "kept: readers matched this book"], result.data.values_at(:outcome, :final, :reason)
            assert_equal ["want_to_read"], UserListItem.joins(:user_list).where(listable: @mixed, user_lists: {user_id: @user.id}).map { |i| i.user_list.list_type }
            assert_equal ["read"], UserListItem.joins(:user_list).where(listable: @to, user_lists: {user_id: @user.id}).map { |i| i.user_list.list_type }
            assert UserListItem.exists?(bystander_item.id), "a user with no applied copy is untouched"
            assert_equal [original.id], kept.reload.payload["deleted"].map { |item| item["id"] }
          end

          test "a copy that applies after the keep step closed reopens it, and the next apply removes the original" do
            kept = mixed_verdict
            kept.update!(payload: kept.payload.merge("kept" => true))
            original = UserListItem.create!(user_list: list(:read), listable: @mixed)
            verdict_a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @mixed, to: @mixed)
            verdict_b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @mixed, to: @to)

            # The keep step closes while no copy from the book has applied yet.
            assert_equal true, Mixed.call(verdict: kept).data[:final]
            kept.update!(applied_at: Time.current, payload: kept.reload.payload.merge("closed_reason" => "kept: readers matched this book"))
            assert UserListItem.exists?(original.id)

            [verdict_a, verdict_b].each do |verdict|
              assert_equal :applied, Row.call(verdict: verdict).data[:outcome]
              verdict.update!(applied_at: Time.current)
            end

            kept.reload
            assert_nil kept.applied_at
            assert_not kept.payload.key?("closed_reason")
            assert_equal true, kept.payload["kept"]
            assert_equal true, Mixed.call(verdict: kept).data[:final]
            assert_not UserListItem.exists?(original.id)
          end

          test "a kept mixed book with row keys and no redirect is final, not waiting" do
            verdict = mixed_verdict(redirect: nil)
            verdict.update!(payload: verdict.payload.merge("kept" => true, "row_keys" => [[1, 1]]))

            result = Mixed.call(verdict: verdict)

            assert_equal [true, "kept: readers matched this book"], result.data.values_at(:final, :reason)
          end

          test "an approved match or a live row anywhere that heads to this book blocks the delete" do
            ::Services::BooksMigration::RedirectRecorder.stubs(:merged)
            row = csv_row
            outside = row_verdict(row, action: "move", from: @from, to: @mixed)
            outside.update!(status: :proposed)
            mixed = mixed_verdict

            result = Mixed.call(verdict: mixed)
            assert_equal [:noop, false], result.data.values_at(:outcome, :final)
            assert ::Books::Book.exists?(@mixed.id)

            outside.update!(status: :rejected)
            match = ::Books::RepairVerdict.reimport_match.find_by!(subject_key: "reimport:edition:#{row.goodreads_edition_id}")
            match.update!(payload: {"outcome" => "matched", "book_id" => @mixed.id})
            assert_equal :noop, Mixed.call(verdict: mixed).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)

            match.update!(status: :rejected)
            assert_equal :applied, Mixed.call(verdict: mixed).data[:outcome]
          end

          test "a keep marked after the verdict was loaded is seen inside the lock, and its payload is not overwritten" do
            stale = mixed_verdict
            ::Books::RepairVerdict.find(stale.id).update!(payload: stale.payload.merge("kept" => true))
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            result = Mixed.call(verdict: stale)

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
            assert ::Books::Book.exists?(@mixed.id)
            assert_equal true, stale.reload.payload["kept"]
          end

          test "images attached after the archive are recorded in the verdict when the book goes" do
            image = Image.new(parent: @mixed, primary: true, notes: "late")
            image.file.attach(io: StringIO.new("late data"), filename: "late.jpg", content_type: "image/jpeg")
            image.save!
            blob = image.file.blob
            verdict = mixed_verdict
            ::Services::BooksMigration::RedirectRecorder.stubs(:merged)

            assert_equal :applied, Mixed.call(verdict: verdict).data[:outcome]

            recorded = verdict.reload.payload["deleted_images"]
            assert_equal [[image.id, "late", blob.key, blob.checksum]],
              recorded.map { |i| [i["id"], i["notes"], i.dig("blob", "key"), i.dig("blob", "checksum")] }
            assert ActiveStorage::Blob.exists?(blob.id)
          end

          test "deleting the book keeps its images' blobs, so the archive can re-attach them" do
            edition = ::Books::Edition.create!(book: @mixed, title: "Ed")
            blobs = [@mixed, edition].map do |parent|
              image = Image.new(parent: parent, primary: false)
              image.file.attach(io: StringIO.new("data #{parent.class}"), filename: "x.jpg", content_type: "image/jpeg")
              image.save!
              image.file.blob
            end
            verdict = mixed_verdict
            verdict.update!(payload: verdict.payload.merge("archive" => MixedBooks.snapshot(@mixed.reload)))
            ::Services::BooksMigration::RedirectRecorder.stubs(:merged)

            # Image purges its file with purge_later; run those jobs, or the test cannot see a purge.
            outcome = perform_enqueued_jobs { Mixed.call(verdict: verdict).data[:outcome] }

            assert_equal :applied, outcome
            archive = verdict.reload.payload["archive"]
            image_ids = archive["images"].map { |i| i["id"] } + archive["editions"].flat_map { |e| e["images"].map { |i| i["id"] } }
            assert_not ::Books::Book.exists?(@mixed.id)
            assert_equal 2, image_ids.size
            assert_equal 0, Image.where(id: image_ids).count
            blobs.each do |blob|
              assert ActiveStorage::Blob.exists?(blob.id), "blob #{blob.id} was purged"
              assert ActiveStorage::Blob.find(blob.id).service.exist?(blob.key)
            end
            keys = archive["images"].map { |i| i.dig("blob", "key") } + archive["editions"].flat_map { |e| e["images"].map { |i| i.dig("blob", "key") } }
            assert_equal blobs.map(&:key).sort, keys.sort
          end

          test "deletes an empty book and records the redirect after commit" do
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).with(item_type: "Books::Book", from_id: @mixed.id, to_id: @to.id)

            result = Mixed.call(verdict: mixed_verdict)

            assert_equal :applied, result.data[:outcome]
            assert_not ::Books::Book.exists?(@mixed.id)
          end

          test "refuses while a reader's list item is left that no copy accounts for" do
            UserListItem.create!(user_list: list(:read), listable: @mixed)

            result = Mixed.call(verdict: mixed_verdict)

            assert_equal [:noop, false], result.data.values_at(:outcome, :final)
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "refuses while a review is left, even for a user whose row was copied" do
            copy_verdict
            Review.create!(user: @user, reviewable: @mixed, rating: 3, body: "mine")

            assert_equal :noop, Mixed.call(verdict: mixed_verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "destroys the originals of an applied copy and records them" do
            item = UserListItem.create!(user_list: list(:read), listable: @mixed, completed_on: Date.new(2020, 5, 5))
            copy_verdict
            verdict = mixed_verdict

            result = Mixed.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_not UserListItem.exists?(item.id)
            deleted = verdict.reload.payload["deleted"].first
            assert_equal [item.id, @user.id, @mixed.id], deleted.values_at("id", "user_id", "listable_id")
          end

          test "another user's item is not a copy original" do
            other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", role: :user, email_verified: false)
            UserListItem.create!(user_list: ::Books::UserList.find_by!(user: other, list_type: :read), listable: @mixed)
            copy_verdict

            assert_equal :noop, Mixed.call(verdict: mixed_verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "an unapplied copy for the same user keeps the book" do
            UserListItem.create!(user_list: list(:read), listable: @mixed)
            copy_verdict
            copy_verdict(applied: false)

            assert_equal :noop, Mixed.call(verdict: mixed_verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "refuses while a guess is unapplied and deletes once it is applied" do
            item = UserListItem.create!(user_list: list(:read), listable: @mixed)
            guess = guess_verdict(item_type: "UserListItem", item_id: item.id, from: @mixed)
            verdict = mixed_verdict

            assert_equal :noop, Mixed.call(verdict: verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)

            Guess.call(verdict: guess)
            guess.update!(applied_at: Time.current)

            assert_equal :applied, Mixed.call(verdict: verdict).data[:outcome]
            assert_not ::Books::Book.exists?(@mixed.id)
          end

          test "an unapplied guess with no entry left on the book does not hold it" do
            guess_verdict(item_type: "UserListItem", item_id: 0, from: @mixed)

            assert_equal :applied, Mixed.call(verdict: mixed_verdict).data[:outcome]
          end

          test "acts only on an approved, current verdict" do
            assert_equal :noop, Mixed.call(verdict: mixed_verdict(status: :proposed)).data[:outcome]
            ::Books::RepairVerdict.delete_all
            assert_equal :noop, Mixed.call(verdict: mixed_verdict(superseded_at: Time.current)).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "a book that is already gone is a final noop" do
            verdict = mixed_verdict
            @mixed.destroy!

            assert_equal [:noop, true], Mixed.call(verdict: verdict).data.values_at(:outcome, :final)
          end

          test "the verdict records that the redirect was written" do
            verdict = mixed_verdict

            Mixed.call(verdict: verdict)

            assert_equal true, verdict.reload.payload["redirect_written"]
          end

          test "a run that died after the delete writes the owed redirect once, then closes" do
            verdict = mixed_verdict
            ::Services::BooksMigration::RedirectRecorder.stubs(:merged).raises(RuntimeError, "boom").then.returns(nil)

            assert_raises(RuntimeError) { Mixed.call(verdict: verdict) }
            assert_not ::Books::Book.exists?(@mixed.id)
            assert_equal false, verdict.reload.payload["redirect_written"]

            ::Services::BooksMigration::RedirectRecorder.expects(:merged).once.with(item_type: "Books::Book", from_id: @mixed.id, to_id: @to.id)
            Mixed.call(verdict: verdict)
            Mixed.call(verdict: verdict.reload)
            assert_equal true, verdict.reload.payload["redirect_written"]
          end

          test "a book another merge removed first gets no redirect from this verdict" do
            verdict = mixed_verdict
            @mixed.destroy!
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            assert_equal [:noop, true], Mixed.call(verdict: verdict).data.values_at(:outcome, :final)
          end

          test "waits, deleting nothing, while its rows have no redirect target yet" do
            verdict = mixed_verdict(redirect: nil)
            verdict.update_columns(payload: verdict.payload.merge("row_keys" => [[@import.id, 1]]))

            result = Mixed.call(verdict: verdict)

            assert_equal [:noop, "waiting for redirect", false], result.data.values_at(:outcome, :reason, :final)
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "no redirect is written when there is no target" do
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            Mixed.call(verdict: mixed_verdict(redirect: nil))
          end
        end
      end
    end
  end
end
