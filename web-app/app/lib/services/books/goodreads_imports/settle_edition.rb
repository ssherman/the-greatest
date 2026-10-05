# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Settles an edition the finder could not match, by its Goodreads page
      # (Goodreads import spec §5 "Outcome", §6):
      #
      # - a page that backs the edition: a provisional book is created with
      #   the page's title and authors, verified;
      # - a page that says the id does not exist, or names another book: the
      #   edition is parked, with its waiting rows, and nothing is created;
      # - no page (the fetcher is down, Goodreads blocked us, the day's cap is
      #   spent): the book is created unverified, for the sweep to check.
      #
      # An edition already created unverified is checked instead: the page
      # sets its verification and the book is left alone. A not-found or
      # mismatched provisional book is the admin page's to act on.
      #
      # ResolveEdition calls this at once when the page is cached, with the
      # finder's live match. Books::Goodreads::SettleEditionsJob calls it after
      # a fetch, and the match is rebuilt from the decision the edition kept:
      # the finder never runs twice. The import that waited owns what is
      # created; if it is gone, the latest import with rows on the edition
      # does; with none, nothing waits for the edition and it is released.
      class SettleEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        PARKED_DETAIL = {not_found: "not found on Goodreads", mismatch: "does not match its Goodreads page"}.freeze

        def self.call(edition:, page:, match: nil, import: nil, importer: ::DataImporters::Books::Book::Importer)
          new(edition: edition, page: page, match: match, import: import, importer: importer).call
        end

        def initialize(edition:, page:, match:, import:, importer:)
          @edition = edition
          @page = page
          @match = match
          @import = import
          @importer = importer
        end

        def call
          return recheck if @edition.created? && @edition.verification_unverified? && @edition.book_id.present?
          return done(:cached) if settled?

          import = @import || owning_import
          return release if import.nil?

          verdict = @page && ::Books::Goodreads::Agreement.call(edition: @edition, page: @page)
          case verdict&.outcome
          when :verified then create(import, page: @page, author_names: verdict.author_names)
          when :not_found, :mismatch then park(verdict.outcome)
          else create(import)
          end
        end

        private

        def recheck
          return done(:unchanged) if @page.nil?

          @edition.update!(verification: ::Books::Goodreads::Agreement.call(edition: @edition, page: @page).outcome)
          done(:rechecked)
        end

        def create(import, page: nil, author_names: nil)
          CreateBook.call(edition: @edition, import: import, match: @match || match_from_decision, importer: @importer,
            page: page, author_names: author_names)
        end

        # Under CreateBook's signature lock, so a racing settle or creation of
        # the same edition sees one or the other.
        def park(verification)
          ActiveRecord::Base.transaction(requires_new: true) do
            CreateBook.lock(@edition)
            @edition.reload
            next done(:cached) if settled?

            decision = @match&.decision || @edition.match_decision
            @edition.update!(book: nil, resolution: :parked, verification: verification, match_decision: decision,
              resolved_at: Time.current, pending_import: nil)
            # Nothing was created, so there is nothing to review.
            decision.update!(needs_review: false) if decision&.needs_review?
            @edition.import_rows.pending.update_all(outcome: ::Books::GoodreadsImportRow.outcomes[:parked],
              outcome_detail: PARKED_DETAIL.fetch(verification), updated_at: Time.current)
            done(:parked)
          end
        end

        # The finder's answer as the edition kept it: the books it considered
        # (so CreateBook still never adopts one it turned down) and the
        # decision. The external answer is not kept, so Open Library is asked
        # again; for a verified creation it would be anyway, because the
        # page's title replaces the edition's.
        def match_from_decision
          decision = @edition.match_decision
          considered = Array(decision&.candidates).filter_map do |snapshot|
            next unless snapshot["record_type"] == "Books::Book"

            book = ::Books::Book.find_by(id: snapshot["record_id"])
            ::DataImporters::Candidate.new(record: book) if book
          end
          ::DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: decision&.confidence&.to_sym,
            decided_by: decision&.decided_by&.to_sym, reason: decision&.reason, candidates: considered, decision: decision)
        end

        def owning_import
          @edition.pending_import ||
            ::Books::GoodreadsImport.where(id: @edition.import_rows.select(:import_id)).order(:id).last
        end

        def release
          @edition.update!(verification: :not_needed, pending_import: nil)
          done(:released)
        end

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
