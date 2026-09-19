# frozen_string_literal: true

require "test_helper"

module Services
  module CsvExports
    class RequestGenerateTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_global)
      end

      test "creates the row, claims it and enqueues the job" do
        ::CsvExports::GenerateJob.expects(:perform_async).with { |id| id == ::CsvExport.last.id }.once

        result = RequestGenerate.call(ranking_configuration: @config)

        assert result.success?, result.errors.inspect
        export = @config.reload.csv_export
        assert export.generating?
        assert_in_delta Time.current, export.requested_at, 5.seconds
        assert_equal export, result.data[:csv_export]
        assert result.data[:csv_export].generating?
      end

      test "reuses the existing row" do
        existing = ::CsvExport.create!(ranking_configuration: @config, status: :ready, generated_at: 1.day.ago, row_count: 42)
        ::CsvExports::GenerateJob.expects(:perform_async).with(existing.id).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
        assert_equal 1, ::CsvExport.where(ranking_configuration: @config).count
        assert existing.reload.generating?
        assert_equal [42, true], [existing.row_count, existing.generated_at.present?]
      end

      test "a failed row is claimable" do
        ::CsvExport.create!(ranking_configuration: @config, status: :failed, error_message: "boom")
        ::CsvExports::GenerateJob.expects(:perform_async).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
      end

      test "refuses while a fresh generation is running and enqueues nothing" do
        ::CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: 2.minutes.ago)
        ::CsvExports::GenerateJob.expects(:perform_async).never

        result = RequestGenerate.call(ranking_configuration: @config)

        refute result.success?
        assert_equal :already_generating, result.data[:reason]
      end

      test "reclaims a generation abandoned longer than the stale window" do
        ::CsvExport.create!(ranking_configuration: @config, status: :generating,
          requested_at: (::CsvExport::GENERATION_STALE_AFTER + 1.minute).ago)
        ::CsvExports::GenerateJob.expects(:perform_async).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
        export = @config.reload.csv_export
        assert export.generating?
        assert_in_delta Time.current, export.requested_at, 5.seconds
      end

      test "only one of two back-to-back calls wins" do
        ::CsvExports::GenerateJob.expects(:perform_async).once

        assert RequestGenerate.call(ranking_configuration: @config).success?
        refute RequestGenerate.call(ranking_configuration: @config).success?
      end

      test "a non-exportable configuration is refused without creating a row" do
        ::CsvExports::GenerateJob.expects(:perform_async).never

        result = RequestGenerate.call(ranking_configuration: ranking_configurations(:books_authors_global))

        refute result.success?
        assert_equal :not_exportable, result.data[:reason]
        assert_equal 0, ::CsvExport.count
      end

      test "an enqueue failure releases the claim into failed with the reason" do
        ::CsvExports::GenerateJob.expects(:perform_async).raises(RedisClient::CannotConnectError, "redis is down")

        result = RequestGenerate.call(ranking_configuration: @config)

        refute result.success?
        assert_equal :enqueue_failed, result.data[:reason]
        assert result.data[:csv_export].failed?
        export = @config.reload.csv_export
        assert export.failed?
        assert_includes export.error_message, "redis is down"
        assert export.claimable?
      end
    end
  end
end
