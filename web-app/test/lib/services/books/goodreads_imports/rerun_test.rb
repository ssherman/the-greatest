require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class RerunTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "rerun@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :failed, error: "boom", finished_at: Time.current)
        end

        test "a failed import is queued again with its unwritten failed rows reset" do
          edition = goodreads_edition(title: "Rerun Book")
          retried = @import.rows.create!(row_number: 1, goodreads_edition: edition, outcome: :failed, error: "resolution failed")
          unparsed = @import.rows.create!(row_number: 2, outcome: :failed, error: "columns do not line up")
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(@import.id)

          assert Rerun.call(import: @import).success?

          assert_equal ["queued", nil, nil], [@import.reload.status, @import.error, @import.finished_at]
          assert_equal ["pending", nil], [retried.reload.outcome, retried.error]
          assert unparsed.reload.failed?
        end

        test "a stuck import can be rerun; a running or complete one cannot" do
          ::Books::Goodreads::RunImportJob.stubs(:perform_async)
          @import.update!(status: :resolving, started_at: 3.hours.ago)
          assert Rerun.call(import: @import).success?

          @import.update!(status: :resolving, started_at: Time.current)
          assert_not Rerun.call(import: @import).success?

          @import.update!(status: :complete)
          assert_not Rerun.call(import: @import).success?
        end

        test "a failed import cannot rerun while the member has another in progress" do
          @user.goodreads_imports.create!(status: :parsing)
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_not Rerun.call(import: @import).success?
        end
      end
    end
  end
end
