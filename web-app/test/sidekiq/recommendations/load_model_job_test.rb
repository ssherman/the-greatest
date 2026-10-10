# frozen_string_literal: true

require "test_helper"

module Recommendations
  class LoadModelJobTest < ActiveSupport::TestCase
    test "runs on the low queue and is scheduled hourly" do
      assert_equal "low", LoadModelJob.get_sidekiq_options["queue"].to_s
      assert_equal false, LoadModelJob.get_sidekiq_options["retry"]
      entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("recommendations_load_books")
      assert_equal "Recommendations::LoadModelJob", entry["class"]
      assert_equal "15 * * * *", entry["cron"]
      assert_equal ["books"], entry["args"]
    end

    test "loads through the default store and raises on failure" do
      Store.stubs(:default).returns(Store::Local.new(Dir.mktmpdir))
      LoadModelJob.new.perform("books")
      LoadModel.stubs(:call).returns(LoadModel::Result.new(success?: false, data: nil, errors: ["short"]))
      error = assert_raises(RuntimeError) { LoadModelJob.new.perform("books") }
      assert_includes error.message, "short"
    end
  end
end
