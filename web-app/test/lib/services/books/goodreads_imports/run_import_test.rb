require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class RunImportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper
        include ActionMailer::TestHelper

        setup do
          stub_resolution_services
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "runner@example.com", role: :user, email_verified: false)
          @book = books_books(:war_and_peace)
        end

        def start(bytes)
          @user.goodreads_imports.create!(status: :queued).tap do |import|
            import.file.attach(io: StringIO.new(bytes), filename: "export.csv", content_type: "text/csv", identify: false)
          end
        end

        def cached_row(book)
          title = "Run Import #{book.id}"
          goodreads_edition(title: title, primary_author: "Leo Tolstoy", goodreads_book_id: 77_000_000 + book.id,
            book: book, resolution: :matched, resolved_at: Time.current)
          {"Book Id" => (77_000_000 + book.id).to_s, "Title" => title, "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"}
        end

        test "a queued import is parsed, resolved, written and completed, and the admin is told" do
          import = start(goodreads_csv(cached_row(@book)))

          assert_enqueued_email_with AdminMailer, :goodreads_import_finished, args: [import] do
            assert_equal :complete, RunImport.call(import: import).data[:outcome]
          end

          import.reload
          assert_equal "complete", import.status
          assert import.started_at.present? && import.finished_at.present?
          assert_equal [1, 1], [import.rows_count, import.matched_count]
          assert import.rows.sole.applied?
        end

        test "an import that is not queued or verifying is left alone" do
          import = start(goodreads_csv(cached_row(@book)))
          import.update!(status: :resolving)

          assert_equal :not_claimed, RunImport.call(import: import).data[:outcome]
          assert_equal 0, import.rows.count
        end

        test "an unreadable file fails the import with the reason and tells the admin" do
          import = start("PK\x03\x04 not a csv".b)

          assert_enqueued_emails 1 do
            assert_equal :failed, RunImport.call(import: import).data[:outcome]
          end
          assert_equal "failed", import.reload.status
          assert_match(/Goodreads export/, import.error)
        end

        test "an import with an edition waiting on Goodreads waits in verifying, then completes on resume" do
          waiting = goodreads_edition(title: "Waiting Book", primary_author: "Anna Brenner", goodreads_book_id: 88_000_001,
            verification: :pending)
          import = start(goodreads_csv({"Book Id" => "88000001", "Title" => "Waiting Book", "Author" => "Anna Brenner",
            "Exclusive Shelf" => "to-read"}))

          assert_equal :verifying, RunImport.call(import: import).data[:outcome]
          assert_equal "verifying", import.reload.status

          waiting.update!(verification: :verified, book: @book, resolution: :created, resolved_at: Time.current)
          assert_equal :complete, RunImport.call(import: import).data[:outcome]
          assert import.reload.complete?
        end

        test "an edition settled between resolve and verifying does not strand the import" do
          waiting = goodreads_edition(title: "Racing Book", primary_author: "Anna Brenner", goodreads_book_id: 88_000_002,
            verification: :pending)
          import = start(goodreads_csv({"Book Id" => "88000002", "Title" => "Racing Book", "Author" => "Anna Brenner",
            "Exclusive Shelf" => "to-read"}))
          # The settle commits after the first check, before the import is verifying.
          RunImport.any_instance.stubs(:waiting?).returns(true).then.returns(false)
          waiting.update!(verification: :verified, book: @book, resolution: :created, resolved_at: Time.current)

          assert_equal :complete, RunImport.call(import: import).data[:outcome]
        end

        test "a replay import sends no email" do
          import = start(goodreads_csv(cached_row(@book)))
          import.update!(source: :legacy_replay, legacy_import_id: 4242)

          assert_no_enqueued_emails { RunImport.call(import: import) }
        end

        test "resume_waiting queues verifying imports with nothing pending" do
          ready = @user.goodreads_imports.create!(status: :verifying)
          other = User.create!(email: "waiter@example.com", role: :user, email_verified: false)
          still = other.goodreads_imports.create!(status: :verifying)
          still.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Still Waiting", verification: :pending))
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(ready.id).once
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(still.id).never

          RunImport.resume_waiting
        end

        test "resume_waiting by Goodreads id looks only at imports naming it" do
          ready = @user.goodreads_imports.create!(status: :verifying)
          ready.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Settled", goodreads_book_id: 88_000_003))
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(ready.id).once

          RunImport.resume_waiting(goodreads_book_id: 88_000_003)
          RunImport.resume_waiting(goodreads_book_id: 1)
        end
      end
    end
  end
end
