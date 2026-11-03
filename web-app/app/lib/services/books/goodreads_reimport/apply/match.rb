# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_match verdict (re-import spec 4.4). matched: the decision becomes the shared edition
        # cache's answer, beating whatever legacy cached. create: the book is made (not provisional: the approved
        # verdict is the approval, rebuild spec 12 call 5) and its id kept in the payload, where DecideRow reads it.
        class Match
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?

            edition = ::Books::GoodreadsEdition.find_by(id: verdict.payload["goodreads_edition_id"])
            return Entries.noop("edition #{verdict.payload["goodreads_edition_id"]} no longer exists") unless edition

            (verdict.payload["outcome"] == "create") ? create(verdict, edition) : cache_match(verdict, edition)
          end

          def self.cache_match(verdict, edition)
            book = GoodreadsReplay::Apply::MergedBook.call(verdict.payload["book_id"])
            return Entries.noop("book #{verdict.payload["book_id"]} no longer exists") unless book
            return Entries.noop("already cached") if edition.book_id == book.id && edition.matched?

            edition.update!(book: book, resolution: :matched, resolved_at: edition.resolved_at || Time.current)
            Entries.applied
          end

          # CreateBook has three outcomes that all leave a book on the edition: made, adopted from a racing
          # import, already cached. The id is stored whichever it was.
          def self.create(verdict, edition)
            existing = ::Books::Book.find_by(id: verdict.payload["created_book_id"])
            return Entries.noop("book #{existing.id} already created") if existing

            import = import_for(edition)
            return Entries.noop("no in-scope row for edition #{edition.id}") unless import

            GoodreadsImports::CreateBook.call(edition: edition, import: import, match: unmatched(verdict, edition), provisional: false)
            book_id = edition.reload.book_id
            return Entries.noop("edition #{edition.id} has no book after create") unless book_id

            verdict.update_columns(payload: verdict.payload.merge("created_book_id" => book_id))
            Entries.applied
          end

          # The newest completed legacy import that names the edition: the import its book is recorded against.
          def self.import_for(edition)
            ::Books::GoodreadsImport.legacy_replay.complete
              .where(id: edition.import_rows.select(:import_id))
              .order(Arel.sql("COALESCE(finished_at, created_at) DESC"), id: :desc).first
          end

          def self.unmatched(verdict, edition)
            decision = ::MatchDecision.find_by(id: verdict.payload["match_decision_id"])
            ::DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule,
              reason: verdict.reason.presence || "re-import: no book matched edition #{edition.id}", decision: decision)
          end

          private_class_method :cache_match, :create, :import_for, :unmatched
        end
      end
    end
  end
end
