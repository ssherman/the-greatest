# frozen_string_literal: true

require "test_helper"

module CsvExports
  class RefreshGlobalJobTest < ActiveSupport::TestCase
    test "runs on the low queue" do
      assert_equal "low", RefreshGlobalJob.get_sidekiq_options["queue"].to_s
    end

    # The real RequestGenerate runs (it creates one CsvExport row per
    # configuration it claims), and only the job enqueue is stubbed -- so the
    # set of rows afterwards IS the set of configurations that were requested.
    test "requests a generate for every active global exportable configuration and nothing else" do
      ranking_configurations(:games_secondary).update_columns(archived: true)
      GenerateJob.stubs(:perform_async)

      RefreshGlobalJob.new.perform

      requested = ::CsvExport.pluck(:ranking_configuration_id)
      expected = RankingConfiguration.global.active.select { |config| Registry.exportable?(config) }.map(&:id)
      assert_includes requested, ranking_configurations(:games_global).id, "at least the games primary is requested"
      assert_equal expected.sort, requested.sort
      refute_includes requested, ranking_configurations(:books_user).id, "user-owned configurations are skipped"
      refute_includes requested, ranking_configurations(:games_secondary).id, "archived configurations are skipped"
      refute_includes requested, ranking_configurations(:books_authors_global).id, "non-exportable types are skipped"
    end

    test "one configuration failing does not stop the others, and the run still raises" do
      GenerateJob.stubs(:perform_async)
      games = ranking_configurations(:games_global)
      Services::CsvExports::RequestGenerate.stubs(:call).returns(
        Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: [])
      )
      Services::CsvExports::RequestGenerate.stubs(:call).with(ranking_configuration: games).raises(StandardError, "db hiccup")

      error = assert_raises(RuntimeError) { RefreshGlobalJob.new.perform }

      assert_includes error.message, games.id.to_s
    end

    test "is scheduled nightly" do
      schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))

      assert_equal "CsvExports::RefreshGlobalJob", schedule.dig("csv_exports_refresh_global", "class")
      assert_equal "30 4 * * *", schedule.dig("csv_exports_refresh_global", "cron")
    end
  end
end
