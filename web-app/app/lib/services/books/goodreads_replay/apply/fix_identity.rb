# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a fix_identity verdict from the Goodreads rebuild: a derived
        # book whose legacy title and authors were a guess gets the export's
        # title, authors and identifiers instead. The book keeps its id, slug and
        # everything users hang on it; ResetBook clears the rest.
        #
        # Re-checked at apply time, not only when the verdict was decided: a
        # book that has become trusted since (a user put it on a real list) is
        # left alone. Passes after the first are no-ops once applied_at is set,
        # so data added after the fix is never wiped again.
        #
        # The reset, the new title and ResetBook's archive (saved on the verdict)
        # commit together, so a crash cannot lose the archive; the import runs
        # after, so a failed author import leaves a book with the right title and
        # no authors, and the next pass finishes it. A retry (whose reset finds
        # nothing left to archive) never overwrites the archive.
        class FixIdentity
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          IMPORT_OPTIONS = {
            force_providers: true, providers: %i[authors query_identifiers], stamp_identifiers: true,
            enrich: false, query_identifier_source: :goodreads_import
          }.freeze

          def self.call(verdict:)
            return noop("already applied") if verdict.applied_at.present?

            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return noop("book #{verdict.payload["book_id"]} no longer exists") unless book
            return noop("book #{book.id} is trusted") if GoodreadsRebuild::Cohort.trusted?(book.id)

            payload = verdict.payload
            ::Books::Book.transaction do
              archive = GoodreadsRebuild::ResetBook.call(book: book).data[:removed]
              save_payload(verdict, "removed" => archive) unless verdict.payload.key?("removed")
              book.update!(title: payload["title"], subtitle: payload["subtitle"], first_published_year: payload["year"])
            end

            imported = import(book, payload)
            save_payload(verdict, "created_author_ids" => (Array(verdict.payload["created_author_ids"]) | imported.created_author_ids).sort)
            failed = imported.provider_results.find { |r| r.provider_name.to_s.end_with?("::Authors") && r.failure? }
            raise Failed, "author import failed: #{failed.errors.join("; ")}" if failed

            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          def self.import(book, payload)
            match = ::DataImporters::Match.new(outcome: :matched, record: book, confidence: :certain, decided_by: :rule,
              reason: "goodreads rebuild fix_identity", candidates: [])
            query = GoodreadsRebuild::ExportFacts.query_attributes(payload).except(:series_name, :series_number)
            ::DataImporters::Books::Book::Importer.call(**query, match: match, **IMPORT_OPTIONS)
          end

          def self.save_payload(verdict, additions)
            verdict.update_columns(payload: verdict.payload.merge(additions))
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :import, :save_payload, :noop
        end
      end
    end
  end
end
