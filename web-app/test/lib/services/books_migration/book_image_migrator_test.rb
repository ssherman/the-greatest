require "test_helper"

module Services
  module BooksMigration
    class BookImageMigratorTest < ActiveSupport::TestCase
      # Stub the join/stream so the legacy replica connection is never opened.
      def run_migrator(rows)
        migrator = BookImageMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def row(overrides = {})
        {"book_id" => 42, "key" => "blobkey", "filename" => "cover.jpg", "content_type" => "image/jpeg"}.merge(overrides)
      end

      test "enqueues one MigrateCoverImageJob per legacy attachment with the blob fields" do
        ::Books::MigrateCoverImageJob.expects(:perform_async).with(42, "blobkey", "cover.jpg", "image/jpeg").once

        result = run_migrator([row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "Books::Book#primary_image", result[:data][:model]
      end

      test "enqueues a job for every row" do
        ::Books::MigrateCoverImageJob.expects(:perform_async).twice

        result = run_migrator([row("book_id" => 1), row("book_id" => 2)])

        assert result[:success], result[:error]
        assert_equal 2, result[:data][:count]
      end
    end
  end
end
