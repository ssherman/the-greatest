# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ExportInteractionsJobTest < ActiveSupport::TestCase
    test "runs on the low queue" do
      assert_equal "low", ExportInteractionsJob.get_sidekiq_options["queue"].to_s
      assert_equal false, ExportInteractionsJob.get_sidekiq_options["retry"]
    end

    test "exports the domain through the default store" do
      store = Store::Local.new(Dir.mktmpdir)
      Store.stubs(:default).returns(store)
      ExportInteractionsJob.new.perform("books")
      assert store.exist?(Paths.interactions_latest(:books))
    end

    test "raises when the export fails" do
      Store.stubs(:default).returns(Store::Local.new(Dir.mktmpdir))
      Export.stubs(:call).returns(Export::Result.new(success?: false, data: nil, errors: ["boom"]))
      error = assert_raises(RuntimeError) { ExportInteractionsJob.new.perform("books") }
      assert_includes error.message, "boom"
    end

    test "is scheduled nightly" do
      entry = YAML.load_file(Rails.root.join("config/schedule.yml")).fetch("recommendations_export_books")
      assert_equal "Recommendations::ExportInteractionsJob", entry["class"]
      assert_equal "30 2 * * *", entry["cron"]
      assert_equal ["books"], entry["args"]
    end
  end
end
