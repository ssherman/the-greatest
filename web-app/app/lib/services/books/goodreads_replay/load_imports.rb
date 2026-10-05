# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Copies the legacy app's Goodreads imports into replay imports (Goodreads
      # import spec §12.1). Each one keeps its legacy id and the user's preserved
      # id. Its upload is downloaded from the legacy R2 bucket once, onto the
      # private service, and its rows are parsed. Statuses:
      # - a legacy import that completed is complete;
      # - a failed or stuck one is failed, with the legacy reason, and still
      #   gets its file and rows, for increment 7 to finish;
      # - a non-CSV upload is failed and never downloaded.
      #
      # Repeatable: an import already loaded is reused and its file is never
      # downloaded again. ParseRows skips rows already written, so a run after
      # the books re-migration truncated the rows parses the kept file again.
      class LoadImports
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        LegacyImport = Data.define(:id, :user_id, :status, :error, :blob_key, :content_type, :filename)
        # The legacy bucket no longer holds the upload's blob (measured: a
        # development load met one). That import fails; the rest still load.
        MissingBlob = Class.new(StandardError)
        CSV_TYPE = "text/csv"

        # The legacy imports, oldest first, each with its upload's blob.
        class LegacyImports
          include Enumerable

          def each
            ::LegacyBooks::GoodreadsImport.includes(file_attachment: :blob).find_each do |import|
              blob = import.file_attachment&.blob
              yield LegacyImport.new(
                id: import.id, user_id: import.user_id, error: import.error,
                status: ::LegacyBooks::GoodreadsImport::STATUSES.fetch(import.status, import.status.to_s),
                blob_key: blob&.key, content_type: blob&.content_type, filename: blob&.filename
              )
            end
          end
        end

        def self.call(legacy_imports: LegacyImports.new, download: nil)
          new(legacy_imports: legacy_imports, download: download).call
        end

        def initialize(legacy_imports:, download:)
          @legacy_imports = legacy_imports
          @download = download || method(:download_from_legacy_r2)
        end

        def call
          tally = Hash.new(0)
          @legacy_imports.each { |legacy| tally[load(legacy)] += 1 }
          Result.new(success?: true, data: {tally: tally.to_h}, errors: [])
        end

        private

        def load(legacy)
          user = ::User.find_by(id: legacy.user_id)
          return :missing_user unless user

          import = ::Books::GoodreadsImport.find_by(legacy_import_id: legacy.id) ||
            ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, legacy_import_id: legacy.id, **initial_state(legacy))
          return :not_csv unless legacy.content_type == CSV_TYPE
          return :missing_file if legacy.blob_key.blank? && !import.file.attached?

          begin
            bytes = bytes_for(import, legacy)
          rescue MissingBlob
            import.update!(status: :failed, error: "legacy upload is missing from the legacy bucket (key #{legacy.blob_key})")
            return :missing_file
          end

          parsed = ::Books::Goodreads::ExportFile.parse(bytes)
          unless parsed.success?
            import.update!(status: :failed, error: "legacy upload unreadable: #{parsed.errors.join("; ")}")
            return :unreadable
          end

          ::Services::Books::GoodreadsImports::ParseRows.call(import: import, rows: parsed.data[:rows])
          :loaded
        end

        def initial_state(legacy)
          return {status: :failed, error: "not a CSV upload: #{legacy.content_type}"} unless legacy.content_type == CSV_TYPE

          case legacy.status
          when "complete" then {status: :complete}
          when "failed" then {status: :failed, error: "legacy import failed: #{legacy.error}"}
          else {status: :failed, error: "legacy import never finished (#{legacy.status})"}
          end
        end

        def bytes_for(import, legacy)
          return import.file.download if import.file.attached?

          bytes = @download.call(legacy.blob_key)
          import.file.attach(io: StringIO.new(bytes), filename: legacy.filename.to_s, content_type: CSV_TYPE, identify: false)
          bytes
        end

        def download_from_legacy_r2(key)
          r2 = ::Services::BooksMigration::LegacyR2
          r2.client.get_object(bucket: r2.bucket, key: key).body.read
        rescue Aws::S3::Errors::NoSuchKey => e
          raise MissingBlob, e.message
        end
      end
    end
  end
end
