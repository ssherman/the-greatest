require "test_helper"

module Admin
  module Books
    class PublisherIntakeControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        # CI has no Redis: the overview's fetch counts come from a stubbed gate.
        config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 10, daily_fetch_cap: 100, block_cooldown: 6.hours.to_i)
        @gate = ::Books::FetchGate.new(key: "test:gate", config: config, label: "test", redis: ::Books::OpenLibrary::FakeRedis.new)
        ::Books::PublisherIntake.stubs(:gate_for).returns(@gate)
      end

      test "an admin sees the overview, with a row for every registered source and a link to its titles" do
        sign_in_as(users(:admin_user), stub_auth: true)
        get admin_books_publisher_intake_path
        assert_response :success

        ::Books::PublisherIntake::Sources.registry.each_key do |key|
          assert_select "[data-testid=source-row][data-source=?]", key
          assert_select "a[href=?]", admin_books_publisher_titles_path(source: key)
        end
      end

      test "the overview renders when a source's gate is blocked" do
        @gate.block!
        sign_in_as(users(:admin_user), stub_auth: true)
        get admin_books_publisher_intake_path
        assert_response :success
        assert_select "[data-testid=source-row]", ::Books::PublisherIntake::Sources.registry.size
      end

      test "the overview renders when the tables are empty" do
        ::Books::PublisherListing.delete_all
        ::Books::PublisherTitle.delete_all
        ::Books::PublisherIntakeRun.delete_all
        sign_in_as(users(:admin_user), stub_auth: true)
        get admin_books_publisher_intake_path
        assert_response :success
        assert_select "[data-testid=source-row]", ::Books::PublisherIntake::Sources.registry.size
      end

      test "a source with rows but no registered strategy still appears" do
        ::Books::PublisherTitle.create!(source: "retired_house", title: "Orphan", isbn13s: ["9780000000002"])
        sign_in_as(users(:admin_user), stub_auth: true)
        get admin_books_publisher_intake_path
        assert_response :success
        assert_select "[data-testid=source-row][data-source=retired_house]"
        assert_select "a[href=?]", admin_books_publisher_titles_path(source: "retired_house")
      end

      test "a signed-out visitor and a regular user are redirected" do
        get admin_books_publisher_intake_path
        assert_redirected_to books_root_path

        sign_in_as(users(:regular_user), stub_auth: true)
        get admin_books_publisher_intake_path
        assert_redirected_to books_root_path
      end
    end
  end
end
