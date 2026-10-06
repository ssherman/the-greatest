require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FinishLegacyImportsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "finisher@example.com", role: :user, email_verified: false)
          @csv = goodreads_csv({"Book Id" => "1001", "Title" => "The Quiet Year", "Author" => "Anna Brenner",
            "Exclusive Shelf" => "read"})
          ::Books::Goodreads::RunImportJob.stubs(:perform_async)
        end

        def legacy(id: 601, status: "pending", created_at: Time.zone.local(2026, 5, 1), user_id: @user.id)
          FinishLegacyImports::LegacyImport.new(id: id, user_id: user_id, status: status, created_at: created_at)
        end

        # The replay import the loader made, with its upload unless bytes is nil.
        def replay(legacy_id: 601, bytes: @csv, user: @user)
          ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, legacy_import_id: legacy_id,
            status: :failed, error: "legacy import never finished (pending)").tap do |import|
            next unless bytes

            import.file.attach(io: StringIO.new(bytes), filename: "goodreads_library_export.csv",
              content_type: "text/csv", identify: false)
          end
        end

        def finish(*legacy_imports, **options)
          FinishLegacyImports.call(legacy_imports: legacy_imports, **options).data[:outcomes]
        end

        def finishing(legacy_id = 601)
          ::Books::GoodreadsImport.find_by(finishes_legacy_import_id: legacy_id)
        end

        test "a stuck legacy import becomes a queued member import of the same user, with a copy of its upload" do
          replay
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with { |id| id == finishing&.id }

          assert_equal({601 => :started}, finish(legacy))

          import = finishing
          assert_predicate import, :member?
          assert_predicate import, :queued?
          assert_equal @user, import.user
          assert_equal @csv, import.file.download
        end

        test "a failed legacy import is finished too" do
          replay

          assert_equal({601 => :started}, finish(legacy(status: "failed")))
        end

        test "a legacy import that completed since the load is left alone" do
          replay

          assert_equal({}, finish(legacy(status: "complete")))
          assert_nil finishing
        end

        test "a later completed legacy import of the same user skips it" do
          replay
          later = legacy(id: 602, status: "complete", created_at: Time.zone.local(2026, 6, 1))

          assert_equal({601 => :later_import_completed}, finish(legacy, later))
          assert_nil finishing
        end

        test "an earlier completed legacy import does not skip it" do
          replay
          earlier = legacy(id: 600, status: "complete", created_at: Time.zone.local(2026, 4, 1))

          assert_equal({601 => :started}, finish(legacy, earlier))
        end

        test "a completed upload in this app skips it" do
          replay
          @user.goodreads_imports.create!(status: :complete)

          assert_equal({601 => :member_import_completed}, finish(legacy))
        end

        test "only the user's newest unfinished import is finished" do
          replay(legacy_id: 601)
          replay(legacy_id: 602)
          newer = legacy(id: 602, created_at: Time.zone.local(2026, 6, 1))

          assert_equal({602 => :started, 601 => :newer_import_finishing}, finish(legacy, newer))
          assert_nil finishing(601)
        end

        test "a newer import with no usable file leaves the older one to finish" do
          replay(legacy_id: 601)
          replay(legacy_id: 602, bytes: nil)
          newer = legacy(id: 602, created_at: Time.zone.local(2026, 6, 1))

          assert_equal({602 => :no_file, 601 => :started}, finish(legacy, newer))
        end

        test "an import the replay has no file for, or an unreadable one, is skipped" do
          assert_equal({601 => :no_file}, finish(legacy))

          replay(bytes: "Title,Author\nThe Quiet Year,Anna Brenner\n")
          assert_equal({601 => :unreadable}, finish(legacy))
          assert_nil finishing
        end

        test "a legacy import whose user is gone is skipped" do
          assert_equal({601 => :missing_user}, finish(legacy(user_id: 0)))
        end

        test "finishing twice in one pass starts it once" do
          replay
          finish(legacy)

          assert_equal({601 => :running}, finish(legacy))
          assert_equal 1, ::Books::GoodreadsImport.where(finishes_legacy_import_id: 601).count
        end

        test "an import that has run this pass is left alone" do
          replay
          finish(legacy)
          finishing.update!(status: :complete)
          finishing.rows.create!(row_number: 1, outcome: :failed, error: "boom")

          assert_equal({601 => :already_run}, finish(legacy))
        end

        test "after a re-migration truncated its rows, it runs again from the kept file, pending review" do
          replay
          finish(legacy)
          import = finishing
          import.update!(status: :complete, finished_at: Time.current, review_status: :approved,
            reviewed_by: users(:admin_user), reviewed_at: Time.current, ai_calls_count: 4)
          import.records.create!(record: books_books(:war_and_peace), action: :created)

          assert_equal({601 => :started}, finish(legacy))

          import.reload
          assert_equal %w[queued pending], [import.status, import.review_status]
          assert_nil import.reviewed_at
          assert_equal 0, import.ai_calls_count
          assert_empty import.records
        end

        test "an import an admin rejected is never finished again" do
          replay
          finish(legacy)
          finishing.update!(status: :complete, review_status: :rejected)

          assert_equal({601 => :rejected}, finish(legacy))
        end

        test "a user with an import in progress is busy, and the batch goes on" do
          replay
          other = User.create!(email: "finisher-two@example.com", role: :user, email_verified: false)
          replay(legacy_id: 602, user: other)
          @user.goodreads_imports.create!(status: :resolving)

          outcomes = finish(legacy, legacy(id: 602, user_id: other.id))

          assert_equal({602 => :started, 601 => :user_busy}, outcomes)
          assert_nil finishing(601)
        end

        test "a dry run says what would start and changes nothing" do
          replay
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_equal({601 => :would_start}, finish(legacy, dry_run: true))
          assert_nil finishing
        end

        test "a limit counts the imports started, newest first, and ids pick legacy imports" do
          other = User.create!(email: "finisher-two@example.com", role: :user, email_verified: false)
          replay(legacy_id: 601)
          replay(legacy_id: 602, user: other)
          newer = legacy(id: 602, user_id: other.id, created_at: Time.zone.local(2026, 6, 1))

          assert_equal({602 => :started}, finish(legacy, newer, limit: 1))
          assert_equal({601 => :started}, finish(legacy, newer, ids: [601]))
        end

        test "a book the stalled legacy import already shelved is not shelved twice" do
          ::Books::Goodreads::RunImportJob.unstub(:perform_async)
          stub_resolution_services
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          book = books_books(:war_and_peace)
          title = "Finish Legacy #{book.id}"
          goodreads_edition(title: title, primary_author: "Leo Tolstoy", goodreads_book_id: 78_000_000 + book.id,
            book: book, resolution: :matched, resolved_at: Time.current)
          replay(bytes: goodreads_csv({"Book Id" => (78_000_000 + book.id).to_s, "Title" => title,
            "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"}))
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          read = ::Books::UserList.find_by!(user: @user, list_type: :read)
          read.user_list_items.create!(listable: book)

          finish(legacy)

          assert_predicate finishing, :complete?
          assert_equal [book.id], read.user_list_items.reload.map(&:listable_id)
          assert_predicate finishing.rows.sole, :skipped?
        end
      end
    end
  end
end
