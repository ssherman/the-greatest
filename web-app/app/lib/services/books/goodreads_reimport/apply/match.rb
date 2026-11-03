# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_match verdict (re-import spec 4.4). matched: the decision becomes the shared edition
        # cache's answer, beating whatever legacy cached. create: the book is made (not provisional: the approved
        # verdict is the approval, rebuild spec 12 call 5) and its id kept in the payload, where DecideRow reads it.
        #
        # Both record the cache they replace in the payload (`edition_before`). A create must first clear it:
        # legacy-replay editions are settled, often on the very mixed book being emptied, and CreateBook returns
        # a settled edition's book as it is. The clear, the create and the payload write share one transaction
        # (and CreateBook's advisory lock), so a failure leaves the old cache in place.
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

            ::ApplicationRecord.transaction do
              remember(verdict, edition)
              edition.update!(book: book, resolution: :matched, resolved_at: edition.resolved_at || Time.current)
            end
            Entries.applied
          end

          # Only a book CreateBook made counts. The one other outcome accepted is adopting a same-signature
          # edition's book made by a racing import; that book must not be the edition's old cache or a mixed
          # book (a legacy edition of the same title can share the signature).
          def self.create(verdict, edition)
            existing = GoodreadsReplay::Apply::MergedBook.call(verdict.payload["created_book_id"])
            return Entries.noop("book #{existing.id} already created") if existing
            return Entries.noop("edition parked") if edition.parked?

            import = import_for(edition)
            return Entries.noop("no in-scope row for edition #{edition.id}") unless import

            reason = nil
            ::ApplicationRecord.transaction do
              GoodreadsImports::CreateBook.lock(edition)
              edition.reload
              before = remember(verdict, edition)
              edition.update!(book: nil, resolution: nil, resolved_at: nil, verification: :not_needed)
              outcome = GoodreadsImports::CreateBook.call(edition: edition, import: import, match: unmatched(verdict, edition),
                provisional: false).data[:outcome]
              book_id = edition.reload.book_id
              reason = refusal(outcome, book_id, before, verdict)
              raise ActiveRecord::Rollback if reason

              verdict.update_columns(payload: verdict.payload.merge("created_book_id" => book_id))
            end
            reason ? Entries.noop(reason) : Entries.applied
          end

          def self.refusal(outcome, book_id, before, verdict)
            return "edition has no book after create" unless book_id
            return "create returned #{outcome}, not a new book" unless %i[created matched].include?(outcome)
            return nil if outcome == :created

            return "create adopted book #{book_id}, the edition's old cache" if book_id == before["book_id"]
            return "create adopted book #{book_id}, a candidate the check turned down" if Array(verdict.payload["candidate_book_ids"]).include?(book_id)

            mixed = ::Books::RepairVerdict.reimport_mixed.approved.current.where("payload->>'book_id' = ?", book_id.to_s).exists?
            "create adopted book #{book_id}, a mixed book" if mixed
          end

          def self.remember(verdict, edition)
            before = verdict.payload["edition_before"] ||
              edition.attributes.slice("book_id", "resolution", "resolved_at", "verification", "match_decision_id", "pending_import_id")
            verdict.update_columns(payload: verdict.payload.merge("edition_before" => before))
            before
          end

          # The newest completed legacy import that names the edition: the import its book is recorded against.
          def self.import_for(edition)
            ::Books::GoodreadsImport.legacy_replay.complete
              .where(id: edition.import_rows.select(:import_id))
              .order(Arel.sql("COALESCE(finished_at, created_at) DESC"), id: :desc).first
          end

          def self.unmatched(verdict, edition)
            decision = ::MatchDecision.find_by(id: verdict.payload["match_decision_id"])
            # The books the check turned down go in as candidates, so CreateBook's racer check leaves them alone.
            candidates = ::Books::Book.where(id: Array(verdict.payload["candidate_book_ids"])).map { |book| ::DataImporters::Candidate.new(record: book) }
            ::DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: :high, decided_by: :rule, candidates: candidates,
              reason: verdict.reason.presence || "re-import: no book matched edition #{edition.id}", decision: decision)
          end

          private_class_method :cache_match, :create, :refusal, :remember, :import_for, :unmatched
        end
      end
    end
  end
end
