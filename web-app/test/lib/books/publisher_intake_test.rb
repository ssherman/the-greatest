# frozen_string_literal: true

require "test_helper"

module Books
  class PublisherIntakeTest < ActiveSupport::TestCase
    test "each source gets its own gate key" do
      redis = ::Books::OpenLibrary::FakeRedis.new
      PublisherIntake.gate_for("hachette_us", redis: redis).block!

      assert_equal [true, false], [
        PublisherIntake.gate_for("hachette_us", redis: redis).blocked?,
        PublisherIntake.gate_for("macmillan_us", redis: redis).blocked?
      ]
    end

    test "settings is the publisher_intake config" do
      assert_same Rails.application.config.x.publisher_intake, PublisherIntake.settings
    end

    test "the client's breaker is not the default page_fetcher one" do
      client = PublisherIntake.client

      assert_instance_of PageFetcher::Client, client
      assert_equal "page_fetcher:publisher_intake", client.breaker.instance_variable_get(:@key)
    end
  end
end
