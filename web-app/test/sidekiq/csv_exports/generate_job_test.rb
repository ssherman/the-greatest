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

    test "is quiet about a row deleted while queued" do
      Services::CsvExports::Generate.expects(:call).never

      assert_nothing_raised { GenerateJob.new.perform(-1) }
    end
  end
end
