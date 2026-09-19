# frozen_string_literal: true

require "tempfile"

# Builds one configuration's full, unfiltered CSV and attaches it (spec §8).
# Runs under a `generating` claim taken by RequestGenerate. The previous
# attachment is only replaced by a successful attach, so a download during a
# failed regeneration still serves the last good file; on failure the row
# carries the message and stays claimable for the next trigger.
#
# Returns a Result rather than raising so the job decides what to raise;
# the job re-raises a failure so it lands in the Sidekiq log.
#
# Model constants are root-anchored: inside Services::CsvExports a bare
# CsvExports resolves to this module.
module Services
  module CsvExports
    class Generate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(csv_export:)
        new(csv_export: csv_export).call
      end

      def initialize(csv_export:)
        @export = csv_export
      end

      def call
        config = export.ranking_configuration
        entry = ::CsvExports::Registry.for_config(config)
        raise "#{config.type} is not exportable" if entry.nil?

        rows = nil
        Tempfile.create(["csv-export-#{export.id}-", ".csv"]) do |file|
          rows = ::CsvExports::RankedItems.call(relation: entry.relation.call(config), row_class: entry.row_class,
            limit: nil, io: file)
          file.flush
          file.rewind

          export.file.attach(io: file, filename: ::CsvExports::Registry.filename_for(config), content_type: "text/csv")
          export.update!(status: :ready, generated_at: Time.current, row_count: rows, byte_size: file.size,
            error_message: nil)
        end

        Result.new(success?: true, data: {csv_export: export, rows: rows}, errors: [])
      rescue => error
        Rails.logger.error "[Services::CsvExports::Generate] export #{export.id}: #{error.class}: #{error.message}"
        ::CsvExport.where(id: export.id).update_all(
          status: ::CsvExport.statuses[:failed],
          error_message: error.message.truncate(500)
        )
        export.reload
        Result.new(success?: false, data: {csv_export: export}, errors: [error.message])
      end

      private

      attr_reader :export
    end
  end
end
