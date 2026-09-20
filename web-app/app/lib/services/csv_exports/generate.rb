# frozen_string_literal: true

require "tempfile"

# Builds one configuration's full, unfiltered CSV and attaches it (spec §8).
# Runs under a `generating` claim taken by RequestGenerate. The previous
# attachment is only replaced by a successful upload plus a single save, so a
# download during a failed regeneration still serves the last good file; on
# failure the row carries the message and stays claimable for the next trigger.
#
# The claim is the run's identity: the row is published only while this run
# still holds it (status `generating`, `requested_at` unchanged since the
# service started). A run that outlived GENERATION_STALE_AFTER -- or sat that
# long in the `low` queue -- may have been re-claimed by a newer worker, and
# must not overwrite that worker's file with an older snapshot; it purges its
# upload and reports `:claim_lost` instead.
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

      CLAIM_LOST = "Another run claimed this export while it was being generated."

      def self.call(csv_export:)
        new(csv_export: csv_export).call
      end

      def initialize(csv_export:)
        @export = csv_export
        # The claim this run holds. Captured before any reload: after with_lock
        # the row may carry a newer worker's stamp.
        @claim_stamp = csv_export.requested_at
      end

      def call
        config = export.ranking_configuration
        entry = ::CsvExports::Registry.for_config(config)
        raise "#{config.type} is not exportable" if entry.nil?

        rows = nil
        published = false
        Tempfile.create(["csv-export-#{export.id}-", ".csv"]) do |file|
          rows = ::CsvExports::RankedItems.call(relation: entry.relation.call(config), row_class: entry.row_class,
            limit: nil, io: file)
          file.flush
          file.rewind

          # Upload before touching the row: `attach(io:)` on a persisted record
          # swaps the attachment rows first and uploads in after_commit, so a
          # storage failure would leave the row pointing at a blob that was never
          # written. create_and_upload! raises before anything references the blob,
          # and the single update! below attaches and stamps in one transaction.
          blob = ActiveStorage::Blob.create_and_upload!(io: file,
            filename: ::CsvExports::Registry.filename_for(config), content_type: "text/csv")

          # Publish only if this run still holds the claim: a run that outlived
          # the stale window may have been re-claimed by a newer worker, and the
          # last writer must not win with an older snapshot. with_lock reloads
          # the row under FOR UPDATE, so the check and the write are atomic.
          export.with_lock do
            if export.generating? && export.requested_at == claim_stamp
              export.update!(file: blob, status: :ready, generated_at: Time.current, row_count: rows,
                byte_size: blob.byte_size, error_message: nil)
              published = true
            end
          end
          blob.purge_later unless published
        end

        return Result.new(success?: false, data: {csv_export: export, reason: :claim_lost}, errors: [CLAIM_LOST]) unless published

        Result.new(success?: true, data: {csv_export: export, rows: rows}, errors: [])
      rescue => error
        Rails.logger.error "[Services::CsvExports::Generate] export #{export.id}: #{error.class}: #{error.message}"
        # Only the claim this run holds: a run that outlived the stale window must
        # not flip a row another worker has since re-claimed.
        ::CsvExport.where(id: export.id, status: ::CsvExport.statuses[:generating], requested_at: claim_stamp).update_all(
          status: ::CsvExport.statuses[:failed],
          error_message: error.message.truncate(500)
        )
        export.reload
        Result.new(success?: false, data: {csv_export: export, reason: :failed}, errors: [error.message])
      end

      private

      attr_reader :export, :claim_stamp
    end
  end
end
