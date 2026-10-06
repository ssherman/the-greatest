require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ApproveTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          ::Books::EnrichBookJob.stubs(:perform_async)
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "approve@example.com", role: :user, email_verified: false)
          @reviewer = users(:admin_user)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @created = provisional_book("Approve Created Book", created_by: @import)
          @junk = provisional_book("Approve Junk Book", created_by: @import)
          @other_import = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          @linked = provisional_book("Approve Linked Book", created_by: @other_import)
          @import.rows.create!(row_number: 3, goodreads_edition: @linked_edition)
        end

        def provisional_book(title, created_by:)
          author = ::Books::Author.create!(name: "#{title} Author", provisional: true)
          book = ::Books::Book.create!(title: title, provisional: true)
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)
          [book, author].each { |record| created_by.records.create!(record: record, action: :created) }
          edition = goodreads_edition(title: title, book: book, resolution: :created, resolved_at: Time.current)
          created_by.rows.create!(row_number: created_by.rows.count + 1, goodreads_edition: edition, outcome: :applied)
          @linked_edition = edition
          book
        end

        test "promotes what it created and what its editions link to, minus the unticked, and records the reviewer" do
          result = Approve.call(import: @import, reviewer: @reviewer, exclude_book_ids: [@junk.id])

          assert result.success?
          assert_not @created.reload.provisional?
          assert_not @linked.reload.provisional?
          assert_not ::Books::Book.exists?(@junk.id)
          assert_equal ["approved", @reviewer.id], [@import.reload.review_status, @import.reviewed_by_id]
          assert @import.reviewed_at.present?
        end

        test "an unticked book something else uses is kept provisional and reported" do
          @other_import.rows.create!(row_number: 9, goodreads_edition: @created.goodreads_editions.first)
          result = Approve.call(import: @import, reviewer: @reviewer, exclude_book_ids: [@created.id])

          assert ::Books::Book.find(@created.id).provisional?
          assert_includes result.data[:kept].map(&:first), @created.id
        end

        test "an unticked id the import did not create is never deleted through it" do
          # Nothing else protects it: only this import's row names it now.
          @other_import.rows.delete_all
          Approve.call(import: @import, reviewer: @reviewer, exclude_book_ids: [@linked.id])

          assert ::Books::Book.exists?(@linked.id)
        end

        test "an unticked author still credited on a promoted book is promoted anyway" do
          author = @created.authors.first
          result = Approve.call(import: @import, reviewer: @reviewer, exclude_author_ids: [author.id])

          assert_not author.reload.provisional?
          assert_includes result.data[:kept].map(&:first), author.id
        end

        test "an import another admin rejected after this request loaded it is not approved" do
          ::Books::GoodreadsImport.where(id: @import.id).update_all(review_status: ::Books::GoodreadsImport.review_statuses[:rejected])

          assert_not Approve.call(import: @import, reviewer: @reviewer).success?
          assert @created.reload.provisional?
          assert @import.reload.review_rejected?
        end

        test "only a finished member import still pending review can be approved" do
          @import.update!(status: :writing)
          assert_not Approve.call(import: @import, reviewer: @reviewer).success?

          @import.update!(status: :complete, review_status: :rejected)
          assert_not Approve.call(import: @import, reviewer: @reviewer).success?

          @import.update!(review_status: :pending, source: :legacy_replay, legacy_import_id: 7001)
          assert_not Approve.call(import: @import, reviewer: @reviewer).success?
          assert @created.reload.provisional?
        end
      end
    end
  end
end
