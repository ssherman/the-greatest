# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ExportInteractionsJobTest < ActiveSupport::TestCase
    PARTIAL_ENV = {"RECOMMENDATIONS_R2_ACCOUNT_ID" => "acct", "RECOMMENDATIONS_R2_ACCESS_KEY" => nil,
                   "RECOMMENDATIONS_R2_SECRET_KEY" => "s", "RECOMMENDATIONS_R2_BUCKET" => "b"}.freeze

    test "runs on the low queue" do
      assert_equal "low", ExportInteractionsJob.get_sidekiq_options["queue"].to_s
      assert_equal false, ExportInteractionsJob.get_sidekiq_options["retry"]
    end

    test "exports the domain through the configured store" do
      store = Store::Local.new(Dir.mktmpdir)
      Store::R2.stubs(:from_env).returns(store)
      ExportInteractionsJob.new.perform("books")
      assert store.exist?(Paths.interactions_latest(:books))
    end

    test "raises when the export fails" do
      Store::R2.stubs(:from_env).returns(Store::Local.new(Dir.mktmpdir))
      Export.stubs(:call).returns(Export::Result.new(success?: false, data: nil, errors: ["boom"]))
      error = assert_raises(RuntimeError) { ExportInteractionsJob.new.perform("books") }
      assert_includes error.message, "boom"
    end

    test "skips with a warning when the store is not configured" do
      Store::R2.stubs(:from_env).returns(nil)
      Export.expects(:call).never
      Rails.logger.expects(:warn).with("[Recommendations::ExportInteractionsJob] recommendations store not configured; skipping")
      assert_nil ExportInteractionsJob.new.perform("books")
    end

    test "raises when the store is only partly configured" do
      Export.expects(:call).never
      with_env(PARTIAL_ENV) do
        assert_raises(Store::NotConfigured) { ExportInteractionsJob.new.perform("books") }
      end
    end

    test "is scheduled nightly" do
      entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("recommendations_export_books")
      assert_equal "Recommendations::ExportInteractionsJob", entry["class"]
      assert_equal "30 2 * * *", entry["cron"]
      assert_equal ["books"], entry["args"]
    end
  end
end
