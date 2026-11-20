require "test_helper"

module Services
  module Books
    module Profiles
      class SaveSettingsTest < ActiveSupport::TestCase
        setup do
          @host = Rails.application.config.domains[:books]
          @public_profile = books_profiles(:public_profile)
          @public_user = users(:profile_reader)
          @private_user = users(:profile_empty_reader)
          ::Books::ReadingGoals::PurgeCachedPagesJob.clear
        end

        test "creates the profile on first save" do
          user = users(:regular_user)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          assert_difference "::Books::Profile.count", 1 do
            result = SaveSettings.call(user: user, attributes: {public: false, show_stats: true})

            assert result.success?
            assert result.data[:persisted]
            assert_nil result.data[:purge_confirmed]
            assert result.data[:profile].show_stats
          end
        end

        test "invalid attributes do not persist and return the model errors" do
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = SaveSettings.call(user: @public_user, attributes: {display_name: ""})

          assert_not result.success?
          assert_not result.data[:persisted]
          assert_includes result.errors, "Display name can't be blank"
          assert_equal "Avid Reader", @public_profile.reload.display_name
        end

        test "making a public profile private purges synchronously and confirms" do
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, [profile_url]).returns(success: true)
          Cloudflare::PurgeService.stubs(:new).returns(purge)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = with_purge_token { SaveSettings.call(user: @public_user, attributes: {public: false}) }

          assert result.success?
          assert result.data[:persisted]
          assert result.data[:purge_confirmed]
          assert_not @public_profile.reload.public?
        end

        test "switching one section off on a public profile purges synchronously" do
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, [profile_url]).returns(success: true)
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          result = with_purge_token { SaveSettings.call(user: @public_user, attributes: {show_reviews: false}) }

          assert result.success?
          assert result.data[:purge_confirmed]
          assert_not @public_profile.reload.show_reviews
        end

        test "changing the display name on a public profile purges synchronously" do
          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, [profile_url]).returns(success: true)
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          result = with_purge_token { SaveSettings.call(user: @public_user, attributes: {display_name: "Someone Else"}) }

          assert result.success?
          assert result.data[:purge_confirmed]
          assert_equal "Someone Else", @public_profile.reload.display_name
        end

        test "switching a section on enqueues the job and does not purge synchronously" do
          @public_profile.update_columns(show_reviews: false)
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", [profile_url])

          result = with_purge_token { SaveSettings.call(user: @public_user, attributes: {show_reviews: true}) }

          assert result.success?
          assert_nil result.data[:purge_confirmed]
          assert @public_profile.reload.show_reviews
        end

        test "a private profile staying private purges nothing" do
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          result = with_purge_token { SaveSettings.call(user: @private_user, attributes: {show_stats: true}) }

          assert result.success?
          assert_nil result.data[:purge_confirmed]
        end

        test "a failed purge keeps the save, enqueues the job, and reports purge_confirmed false" do
          purge = mock("purge")
          purge.expects(:purge_urls).returns(success: false, error: "edge unavailable")
          Cloudflare::PurgeService.stubs(:new).returns(purge)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", [profile_url])
          Rails.logger.stubs(:error)
          Rails.logger.expects(:error).with("[ALERT] Books profile #{@public_profile.id} hid content but cache revocation failed: edge unavailable")

          result = with_purge_token { SaveSettings.call(user: @public_user, attributes: {public: false}) }

          assert_not result.success?
          assert result.data[:persisted]
          assert_equal false, result.data[:purge_confirmed]
          assert_includes result.errors, "edge unavailable"
          assert_not @public_profile.reload.public?
        end

        test "a raising purge is handled the same way" do
          purge = mock("purge")
          purge.expects(:purge_urls).raises(StandardError.new("connection reset"))
          Cloudflare::PurgeService.stubs(:new).returns(purge)
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", [profile_url])

          result = with_purge_token { SaveSettings.call(user: @public_user, attributes: {public: false}) }

          assert_not result.success?
          assert result.data[:persisted]
          assert_equal false, result.data[:purge_confirmed]
          assert_includes result.errors, "connection reset"
          assert_not @public_profile.reload.public?
        end

        test "without a purge token outside production a hide is confirmed without constructing the service" do
          Cloudflare::PurgeService.expects(:new).never

          result = with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => nil) do
            SaveSettings.call(user: @public_user, attributes: {public: false})
          end

          assert result.success?
          assert result.data[:purge_confirmed]
        end

        test "publishing a private profile enqueues the job" do
          private_profile = books_profiles(:private_profile)
          url = "https://#{@host}/profiles/#{private_profile.id}"
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", [url])

          result = SaveSettings.call(user: @private_user, attributes: {public: true, display_name: "Newly Public"})

          assert result.success?
          assert_nil result.data[:purge_confirmed]
          assert private_profile.reload.public?
        end

        test "private -> public -> private purges on the second hide" do
          private_profile = books_profiles(:private_profile)
          url = "https://#{@host}/profiles/#{private_profile.id}"
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", [url])
          SaveSettings.call(user: @private_user, attributes: {public: true, display_name: "Newly Public"})

          purge = mock("purge")
          purge.expects(:purge_urls).with(:books, [url]).returns(success: true)
          Cloudflare::PurgeService.stubs(:new).returns(purge)

          result = with_purge_token { SaveSettings.call(user: @private_user, attributes: {public: false}) }

          assert result.success?
          assert result.data[:purge_confirmed]
        end

        test "nothing is enqueued when an enclosing transaction rolls back" do
          Cloudflare::PurgeService.expects(:new).never
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).never

          @public_profile.update_columns(show_reviews: false)
          with_purge_token do
            ::Books::Profile.transaction(requires_new: true) do
              SaveSettings.call(user: @public_user, attributes: {show_reviews: true})
              raise ActiveRecord::Rollback
            end
          end
        end

        private

        def profile_url
          "https://#{@host}/profiles/#{@public_profile.id}"
        end

        def with_purge_token(&block)
          with_env("CLOUDFLARE_CACHE_PURGE_TOKEN" => "test-token", &block)
        end
      end
    end
  end
end
