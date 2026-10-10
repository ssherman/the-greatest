# frozen_string_literal: true

require "test_helper"

module Recommendations
  class LoadModelJobTest < ActiveSupport::TestCase
    PARTIAL_ENV = {"RECOMMENDATIONS_R2_ACCOUNT_ID" => "acct", "RECOMMENDATIONS_R2_ACCESS_KEY" => nil,
                   "RECOMMENDATIONS_R2_SECRET_KEY" => "s", "RECOMMENDATIONS_R2_BUCKET" => "b"}.freeze

    test "runs on the low queue and is scheduled hourly" do
      assert_equal "low", LoadModelJob.get_sidekiq_options["queue"].to_s
      assert_equal false, LoadModelJob.get_sidekiq_options["retry"]
      entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("recommendations_load_books")
      assert_equal "Recommendations::LoadModelJob", entry["class"]
      assert_equal "15 * * * *", entry["cron"]
      assert_equal ["books"], entry["args"]
    end

    test "loads through the configured store and raises on failure" do
      Store::R2.stubs(:from_env).returns(Store::Local.new(Dir.mktmpdir))
      LoadModelJob.new.perform("books")
      LoadModel.stubs(:call).returns(LoadModel::Result.new(success?: false, data: nil, errors: ["short"]))
      error = assert_raises(RuntimeError) { LoadModelJob.new.perform("books") }
      assert_includes error.message, "short"
    end

    test "skips with a warning when the store is not configured" do
      Store::R2.stubs(:from_env).returns(nil)
      LoadModel.expects(:call).never
      Rails.logger.expects(:warn).with("[Recommendations::LoadModelJob] recommendations store not configured; skipping")
      assert_nil LoadModelJob.new.perform("books")
    end

    test "raises when the store is only partly configured" do
      LoadModel.expects(:call).never
      with_env(PARTIAL_ENV) do
        assert_raises(Store::NotConfigured) { LoadModelJob.new.perform("books") }
      end
    end
  end
end
