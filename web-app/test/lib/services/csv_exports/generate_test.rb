# frozen_string_literal: true

require "test_helper"

module Services
  module CsvExports
    class GenerateTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @config = ranking_configurations(:games_global)
        @export = ::CsvExport.create!(ranking_configuration: @config, status: :generating, requested_at: Time.current,
          error_message: "old failure")
      end

      test "attaches the full unfiltered ranking and stamps the row ready" do
        result = Generate.call(csv_export: @export)

        assert result.success?, result.errors.inspect
        @export.reload
        assert @export.ready?
        assert @export.file.attached?
        assert_equal 4, @export.row_count
        assert_nil @export.error_message
        assert_in_delta Time.current, @export.generated_at, 5.seconds

        # Blob#download returns binary; the file is UTF-8, BOM first.
        body = @export.file.download.force_encoding(Encoding::UTF_8)
        assert body.start_with?(::CsvExports::Writer::BOM)
        assert_equal @export.byte_size, body.bytesize
        parsed = CSV.parse(body.delete_prefix(::CsvExports::Writer::BOM))
        assert_equal ::CsvExports::Games::RankedGameRow::HEADERS, parsed.first
        assert_equal 5, parsed.size
        assert_equal "the-greatest-games-rankings-#{Date.current.iso8601}.csv", @export.file.filename.to_s
      end

      test "a failure marks the row failed with the message and keeps the previous file" do
        @export.file.attach(io: StringIO.new("#{::CsvExports::Writer::BOM}old\n"), filename: "old.csv", content_type: "text/csv")
        ::CsvExports::RankedItems.stubs(:call).raises(StandardError, "opensearch exploded")

        result = Generate.call(csv_export: @export)

        refute result.success?
        assert_equal ["opensearch exploded"], result.errors
        @export.reload
        assert @export.failed?
        assert_equal "opensearch exploded", @export.error_message
        assert_equal "#{::CsvExports::Writer::BOM}old\n", @export.file.download.force_encoding(Encoding::UTF_8)
      end

      test "a storage upload failure leaves the previous file attached and records the failure" do
        @export.file.attach(io: StringIO.new("#{::CsvExports::Writer::BOM}old\n"), filename: "old.csv", content_type: "text/csv")
        ActiveStorage::Service::DiskService.any_instance.stubs(:upload).raises(StandardError, "r2 hiccup")

        result = Generate.call(csv_export: @export)

        refute result.success?
        @export.reload
        assert @export.failed?
        assert_equal "r2 hiccup", @export.error_message
        assert_equal "#{::CsvExports::Writer::BOM}old\n", @export.file.download.force_encoding(Encoding::UTF_8)
      end

      test "a successful regeneration replaces the file and purges the old blob" do
        @export.file.attach(io: StringIO.new("#{::CsvExports::Writer::BOM}old\n"), filename: "old.csv", content_type: "text/csv")
        old_blob = @export.file.blob

        assert_enqueued_with(job: ActiveStorage::PurgeJob, args: [old_blob]) do
          assert Generate.call(csv_export: @export).success?
        end

        @export.reload
        refute_equal old_blob.id, @export.file.blob.id
        assert_equal 4, @export.row_count
      end

      test "a run that lost its claim steps aside, purges its upload and leaves the row to the new owner" do
        @export.file.attach(io: StringIO.new("#{::CsvExports::Writer::BOM}old\n"), filename: "old.csv", content_type: "text/csv")
        old_blob = @export.file.blob
        # Another worker re-claimed the row after this run started.
        ::CsvExport.where(id: @export.id).update_all(requested_at: 1.second.from_now)

        result = nil
        assert_enqueued_with(job: ActiveStorage::PurgeJob) { result = Generate.call(csv_export: @export) }

        refute result.success?
        assert_equal :claim_lost, result.data[:reason]
        @export.reload
        assert @export.generating?, "the row still belongs to the newer claim"
        assert_equal old_blob.id, @export.file.blob.id
        assert_equal "old failure", @export.error_message, "the row is left exactly as the new owner had it"
      end

      test "a failure after a lost claim does not touch the new owner's row" do
        ::CsvExport.where(id: @export.id).update_all(requested_at: 1.second.from_now)
        ::CsvExports::RankedItems.stubs(:call).raises(StandardError, "boom")

        Generate.call(csv_export: @export)

        assert @export.reload.generating?
      end

      test "a failure after the lock reloaded a newer claim still leaves the new owner's row alone" do
        ::CsvExport.where(id: @export.id).update_all(requested_at: 1.second.from_now)
        # The step-aside purge is the first thing that can fail after with_lock
        # has reloaded the row with the other worker's stamp.
        ActiveStorage::Blob.any_instance.stubs(:purge_later).raises(StandardError, "purge boom")

        result = Generate.call(csv_export: @export)

        refute result.success?
        assert_equal :failed, result.data[:reason]
        @export.reload
        assert @export.generating?, "the failure must be scoped to the claim this run held, not the reloaded one"
        assert_equal "old failure", @export.error_message
      end

      test "a configuration that stopped being exportable fails cleanly" do
        @export.update_columns(ranking_configuration_id: ranking_configurations(:books_authors_global).id)

        # A fresh load: @export still holds games_global as its cached association target.
        result = Generate.call(csv_export: ::CsvExport.find(@export.id))

        refute result.success?
        assert @export.reload.failed?
      end
    end
  end
end
