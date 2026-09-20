# frozen_string_literal: true

require "test_helper"

module CsvExports
  class GenerateJobTest < ActiveSupport::TestCase
    setup do
      @export = ::CsvExport.create!(ranking_configuration: ranking_configurations(:games_global),
        status: :generating, requested_at: Time.current)
    end

    test "runs on the low queue and never retries" do
      assert_equal "low", GenerateJob.get_sidekiq_options["queue"].to_s
      assert_equal false, GenerateJob.get_sidekiq_options["retry"]
    end

    test "generates the export" do
      GenerateJob.new.perform(@export.id)

      assert @export.reload.ready?
      assert @export.file.attached?
    end

    test "raises when generation fails so the failure reaches the Sidekiq log" do
      Services::CsvExports::Generate.expects(:call).returns(
        Services::CsvExports::Generate::Result.new(success?: false, data: {}, errors: ["boom"])
      )

      error = assert_raises(RuntimeError) { GenerateJob.new.perform(@export.id) }

      assert_includes error.message, "boom"
    end

    test "re-requests a generation when a rerun was asked for during the run" do
      Services::CsvExports::Generate.stubs(:call).with { |csv_export:|
        ::CsvExport.where(id: csv_export.id).update_all(status: ::CsvExport.statuses[:ready], rerun_requested: true)
        true
      }.returns(Services::CsvExports::Generate::Result.new(success?: true, data: {}, errors: []))
      Services::CsvExports::RequestGenerate.expects(:call)
        .with(ranking_configuration: @export.ranking_configuration).once
        .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))

      GenerateJob.new.perform(@export.id)
    end

    test "does not re-request when no rerun was asked for" do
      Services::CsvExports::RequestGenerate.expects(:call).never

      GenerateJob.new.perform(@export.id)

      assert @export.reload.ready?
    end

    test "steps aside without raising when the claim was lost" do
      Services::CsvExports::Generate.expects(:call).returns(
        Services::CsvExports::Generate::Result.new(success?: false, data: {reason: :claim_lost}, errors: ["lost"])
      )
      Services::CsvExports::RequestGenerate.expects(:call).never

      assert_nothing_raised { GenerateJob.new.perform(@export.id) }
    end

    test "is quiet about a row deleted while queued" do
      Services::CsvExports::Generate.expects(:call).never

      assert_nothing_raised { GenerateJob.new.perform(-1) }
    end
  end
end
