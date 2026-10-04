# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Creates the provisional book for an edition the finder could not
      # match, and records what it made (Goodreads import spec §5, "Creating a
      # book" and "Locking").
      #
      # The advisory lock is keyed by the edition's signature (normalized
      # title plus primary author), so two imports racing to create one book,
      # through the same Goodreads id or two editions of the same title and
      # author, take turns here. Under the lock the edition is re-read (the
      # other import may have resolved it), then editions with the same
      # signature are checked for a book created since the finder looked.
      # Only then is a book created. Books the finder already considered are
      # left out of that check: a book it saw and turned down, an AI "none"
      # included, stays turned down.
      #
      # The book goes through the book importer with the finder's match (no
      # second finder run), provisional, with the edition's identifiers
      # stamped and no enrichment; enrichment runs on admin approval. With no
      # Goodreads fetcher yet (increment 4), every creation is unverified.
      class CreateBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        CreateFailed = Class.new(StandardError)

        # The subquery gives the result a type the adapter knows:
        # pg_advisory_xact_lock returns void (see Services::Billing::ReconcileCustomer).
        LOCK_SQL = "SELECT 1 AS locked FROM (SELECT pg_advisory_xact_lock(hashtext($1)::bigint)) AS lock_taken"

        def self.call(edition:, import:, match:, importer: ::DataImporters::Books::Book::Importer)
          new(edition: edition, import: import, match: match, importer: importer).call
        end

        def initialize(edition:, import:, match:, importer:)
          @edition = edition
          @import = import
          @match = match
          @importer = importer
        end

        # requires_new: inside a caller's transaction (the dry run, a test, a
        # future job) a CreateFailed must still roll back what the providers
        # already saved -- a book with no author, a new author -- rather than
        # leave it for the next edition to find.
        def call
          ActiveRecord::Base.transaction(requires_new: true) do
            acquire_lock
            @edition.reload
            next done(:cached) if settled?

            racer = book_created_since_the_finder_looked
            next adopt(racer) if racer

            create
          end
        end

        private

        def acquire_lock
          ActiveRecord::Base.connection.exec_query(LOCK_SQL, "goodreads-create-lock", ["goodreads-edition:#{@edition.signature}"])
        end

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def book_created_since_the_finder_looked
          considered = @match.candidates.select(&:local?).map { |candidate| candidate.record.id }
          ::Books::GoodreadsEdition.created
            .where(signature: @edition.signature)
            .where.not(id: @edition.id)
            .where.not(book_id: [nil, *considered])
            .order(:resolved_at, :id)
            .first&.book
        end

        def adopt(book)
          @match.decision&.update!(record: book)
          resolve!(book, :matched, :not_needed)
          done(:matched)
        end

        def create
          result = @importer.call(
            title: @edition.title,
            author_names: [@edition.primary_author],
            year: @edition.original_publication_year || @edition.year_published,
            isbn13: [@edition.isbn13].compact,
            isbn10: [@edition.isbn10].compact,
            goodreads_id: [@edition.goodreads_book_id.to_s],
            subject: @edition,
            match: @match,
            provisional: true,
            stamp_identifiers: true,
            enrich: false
          )
          book = result.item
          unless result.created? && book&.persisted?
            raise CreateFailed, "no book created for Goodreads edition #{@edition.id}: #{result.all_errors.join("; ")}"
          end
          # An authorless book is legacy root cause 5: no later author-required
          # search can find it. The importer saves one when the author step
          # fails and a later provider succeeds.
          unless ::Books::BookAuthor.exists?(book: book)
            raise CreateFailed, "the book for Goodreads edition #{@edition.id} got no author: #{result.all_errors.join("; ")}"
          end

          record_provenance(book, result.created_author_ids)
          resolve!(book, :created, :unverified)
          done(:created)
        end

        def record_provenance(book, created_author_ids)
          records = [book] +
            ::Books::BookAuthor.where(book: book).to_a +
            ::Identifier.where(identifiable: book).to_a +
            ::Books::Author.where(id: created_author_ids).to_a
          records.each { |record| @import.records.create!(record: record, action: :created) }
        end

        def resolve!(book, resolution, verification)
          @edition.update!(book: book, resolution: resolution, verification: verification,
            match_decision: @match.decision, resolved_at: Time.current)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
