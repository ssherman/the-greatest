# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Drives one import through its phases (Goodreads import spec §5–§7,
      # §13): parse the file, resolve every edition, wait for Goodreads where
      # an edition needs its page, write the library, complete. Every phase can
      # run again: rows are parsed once, editions resolve once, writes skip on
      # conflict.
      #
      # An import is claimed by a conditional update from queued or verifying,
      # so the job, the settle job's resume and the sweep can all ask for a run
      # and only one does it. After an import is set verifying, the waiting
      # editions are checked again: a settle that finished in between found
      # nothing verifying to resume, so this run carries on itself.
      #
      # A failure fails the import with the error; Postgres errors re-raise
      # after that. A member import emails the admin once it completes or
      # fails; replay imports send nothing.
      class RunImport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze
        UNREADABLE = "the uploaded file is not a readable Goodreads export"

        def self.call(import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(import: import, finder: finder, importer: importer).call
        end

        # Queues a run for every verifying import that no longer waits on any
        # edition: those naming goodreads_book_id, or all of them.
        def self.resume_waiting(goodreads_book_id: nil)
          imports = ::Books::GoodreadsImport.verifying
          if goodreads_book_id
            imports = imports.where(id: ::Books::GoodreadsImportRow.joins(:goodreads_edition)
              .where(books_goodreads_editions: {goodreads_book_id: goodreads_book_id}).select(:import_id))
          end
          imports.find_each do |import|
            next if import.editions.verification_pending.exists?

            ::Books::Goodreads::RunImportJob.perform_async(import.id)
          end
        end

        def initialize(import:, finder:, importer:)
          @import = import
          @finder = finder
          @importer = importer
        end

        def call
          resuming = @import.verifying?
          return done(:not_claimed) unless claim(from: resuming ? :verifying : :queued, to: resuming ? :resolving : :parsing)

          @import.reload
          parse unless resuming
          @import.update!(status: :resolving)
          ResolveImport.call(import: @import, finder: @finder, importer: @importer)
          return done(:verifying) if wait_for_goodreads

          @import.update!(status: :writing)
          WriteLibrary.call(import: @import)
          finish(:complete)
        rescue => e
          fail!(e)
          raise if POSTGRES_ERRORS.any? { |klass| e.is_a?(klass) }

          done(:failed)
        end

        private

        def claim(from:, to:)
          now = Time.current
          ::Books::GoodreadsImport.where(id: @import.id, status: from)
            .update_all([
              "status = ?, started_at = COALESCE(started_at, ?), updated_at = ?",
              ::Books::GoodreadsImport.statuses[to], now, now
            ]) == 1
        end

        def parse
          parsed = ::Books::Goodreads::ExportFile.parse(@import.file.download)
          raise ArgumentError, "#{UNREADABLE}: #{parsed.errors.join("; ")}" unless parsed.success?

          ParseRows.call(import: @import, rows: parsed.data[:rows])
        end

        # True when the import now waits in verifying for a settle to resume it.
        def wait_for_goodreads
          return false unless waiting?

          @import.update!(status: :verifying)
          return true if waiting?

          # Nothing waits any more, and a settle may have queued a resume:
          # whoever claims verifying first writes the library.
          taken_elsewhere = !claim(from: :verifying, to: :writing)
          @import.reload
          taken_elsewhere
        end

        def waiting?
          @import.editions.verification_pending.exists?
        end

        def finish(status)
          @import.update!(status: status, finished_at: Time.current, error: nil)
          notify
          done(status)
        end

        def fail!(error)
          Rails.logger.error("#{self.class.name}: Goodreads import #{@import.id} failed: #{error.class}: #{error.message}")
          @import.update_columns(status: ::Books::GoodreadsImport.statuses[:failed], error: "#{error.class}: #{error.message}",
            finished_at: Time.current, updated_at: Time.current)
          notify
        rescue *POSTGRES_ERRORS
          nil
        end

        def notify
          AdminMailer.goodreads_import_finished(@import).deliver_later if @import.member?
        end

        def done(outcome)
          Result.new(success?: outcome != :failed, data: {outcome: outcome}, errors: [])
        end
      end
    end
  end
end
