require "test_helper"

module Services
  module Books
    module Profiles
      # Real transactions are needed here: the fixture transaction of a normal
      # test is not joinable, so it cannot stand in for a caller's transaction.
      class SaveSettingsTransactionTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          @user = User.create!(email: "hide-in-txn-#{SecureRandom.hex(4)}@example.com", name: "Hide Txn")
          @profile = ::Books::Profile.create!(user: @user, public: true, display_name: "Txn Reader", show_stats: true)
          ::Books::ReadingGoals::PurgeCachedPagesJob.clear
        end

        teardown do
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          ::Books::Profile.where(user_id: @user.id).delete_all
          @user.destroy
        end

        test "a hide inside an enclosing transaction is refused and nothing is saved or purged" do
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token") do
            ::Books::Profile.transaction do
              SaveSettings.call(user: @user, attributes: {public: false})
            end
          end

          assert_not result.success?
          assert_not result.data[:persisted]
          assert_nil result.data[:purge_confirmed]
          assert_equal ["Hiding profile content cannot run inside an existing transaction"], result.errors
          assert @profile.reload.public?
        end

        test "the same hide outside a transaction succeeds" do
          purge = mock("purge")
          purge.expects(:purge_urls).returns(success: true)
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          result = with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token") do
            SaveSettings.call(user: @user, attributes: {public: false})
          end

          assert result.success?
          assert result.data[:purge_confirmed]
          assert_not @profile.reload.public?
        end
      end
    end
  end
end
