# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Refuses an upload before any import row exists (Goodreads import spec
      # §4): no file, too large, not a Goodreads export, no rows, an import
      # already running, or the daily limit spent. The errors are shown to the
      # member as they are.
      class ValidateUpload
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        DEFAULT_FILENAME = "goodreads_library_export.csv"

        def self.call(user:, upload:)
          new(user: user, upload: upload).call
        end

        def initialize(user:, upload:)
          @user = user
          @upload = upload
        end

        def call
          return refuse("Choose your Goodreads export file first.") if @upload.blank?
          if @upload.size > config.max_file_bytes
            return refuse("That file is over #{config.max_file_bytes / 1.megabyte} MB. A Goodreads export is much smaller, so check you picked the right file.")
          end
          return refuse("You already have an import running. You can upload another when it finishes.") if @user.goodreads_imports.in_progress.exists?
          if @user.goodreads_imports.member.where(created_at: 24.hours.ago..).count >= config.daily_limit
            return refuse("You can start #{config.daily_limit} imports a day. Try again tomorrow.")
          end

          bytes = @upload.read.to_s.b
          parsed = ::Books::Goodreads::ExportFile.parse(bytes)
          unless parsed.success?
            return refuse("That isn't a Goodreads library export. Export your library from Goodreads and upload the CSV file it gives you.")
          end
          return refuse("That export has no books in it.") if parsed.data[:rows].empty?

          Result.new(success?: true, data: {bytes: bytes, rows: parsed.data[:rows], filename: filename}, errors: [])
        end

        private

        def config = Rails.application.config.x.goodreads_imports

        def filename
          name = @upload.respond_to?(:original_filename) ? @upload.original_filename.to_s : ""
          ActiveStorage::Filename.new(name.presence || DEFAULT_FILENAME).sanitized
        end

        def refuse(message)
          Result.new(success?: false, data: {}, errors: [message])
        end
      end
    end
  end
end
