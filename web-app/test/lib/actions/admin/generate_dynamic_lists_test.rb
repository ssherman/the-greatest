# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class GenerateDynamicListsTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @year_config = ranking_configurations(:books_year_2025)
      end

      test "name and message" do
        assert_equal "Generate Dynamic Lists", GenerateDynamicLists.name
        assert_not_empty GenerateDynamicLists.message
      end

      test "visible only on the show view" do
        assert GenerateDynamicLists.visible?(view: :show)
        assert_not GenerateDynamicLists.visible?(view: :index)
      end

      test "errors unless exactly one configuration is given" do
        assert GenerateDynamicLists.call(user: @user, models: []).error?
      end

      test "errors on a configuration with no year" do
        result = GenerateDynamicLists.call(user: @user, models: [ranking_configurations(:books_global)])

        assert result.error?
        assert_match(/no year/, result.message)
      end

      test "queues the job for a year configuration" do
        GenerateDynamicListsJob.expects(:perform_async).with(@year_config.id).once

        result = GenerateDynamicLists.call(user: @user, models: [@year_config])

        assert result.success?
        assert_match(/2025/, result.message)
      end
    end
  end
end
