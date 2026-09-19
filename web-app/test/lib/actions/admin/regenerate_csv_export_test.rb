# frozen_string_literal: true

require "test_helper"

module Actions
  module Admin
    class RegenerateCsvExportTest < ActiveSupport::TestCase
      setup do
        @user = users(:admin_user)
        @config = ranking_configurations(:books_global)
      end

      test "name and message" do
        assert_equal "Regenerate CSV Export", RegenerateCsvExport.name
        assert_not_empty RegenerateCsvExport.message
      end

      test "visible only on the show view" do
        assert RegenerateCsvExport.visible?(view: :show)
        assert_not RegenerateCsvExport.visible?(view: :index)
      end

      test "errors unless exactly one configuration is given" do
        assert RegenerateCsvExport.call(user: @user, models: []).error?
      end

      test "requests a generate and reports success" do
        Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @config)
          .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))

        result = RegenerateCsvExport.call(user: @user, models: [@config])

        assert result.success?
        assert_includes result.message, @config.name
      end

      test "surfaces a refused request as an error" do
        result = RegenerateCsvExport.call(user: @user, models: [ranking_configurations(:books_authors_global)])

        assert result.error?
        assert_equal Services::CsvExports::RequestGenerate::NOT_EXPORTABLE, result.message
      end
    end
  end
end
