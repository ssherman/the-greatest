# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Settles a submission on a book: the finder's match, a book another
      # submission or a Goodreads import created with the same signature, or a
      # new provisional one. It writes the book's half of the submission and no
      # more: book, created_book, match_decision, signature, the resolved title
      # and authors, and review_status. status stays looking_up and the list,
      # the lookups and `added` are ProcessSubmission's, after this commits, so
      # a crash anywhere resumes from the book instead of making another.
      #
      # The advisory lock is the one GoodreadsImports::CreateBook takes, keyed
      # by the same signature, so a submission and an import racing to create
      # one book take turns. Under it the submission row is locked and re-read:
      # a reader who cancelled while no book existed wins, and nothing is
      # created. Then a book created since the finder looked is adopted, except
      # one the finder already considered and turned down. A matched book is
      # recorded as is. Only otherwise does the book importer run, provisional,
      # with the submission's own identifiers stamped as user_submission and no
      # enrichment. A book with no author is rolled back whole (an authorless
      # book can never be found by an author search); the savepoint takes the
      # authors the importer saved with it.
      #
      # data[:outcome] is :created, :matched, :adopted or :resumed (the
      # submission already had its book), each with data[:book] and
      # data[:created]; or, with success? false, :aborted (no longer open),
      # :no_owner (the reader or the list is gone, and nobody is left to want
      # the book: nothing is created) or :no_author.
      class CreateBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        NoAuthor = Class.new(StandardError)
        CreateFailed = Class.new(StandardError)

        LOCK_SQL = ::Services::Books::GoodreadsImports::CreateBook::LOCK_SQL

        def self.call(submission:, resolved:, match:, importer: ::DataImporters::Books::Book::Importer)
          new(submission: submission, resolved: resolved, match: match, importer: importer).call
        end

        # Held until the caller's transaction ends.
        def self.lock(signature)
          ActiveRecord::Base.connection.exec_query(LOCK_SQL, "book-submission-create-lock", ["goodreads-edition:#{signature}"])
        end

        def initialize(submission:, resolved:, match:, importer:)
          @submission = submission
          @resolved = resolved
          @match = match
          @importer = importer
          @title = resolved[:title]
          @author_names = resolved[:author_names]
          @signature = ::Books::Goodreads::ExportRow.signature(@title, @author_names.first)
        end

        def call
          ActiveRecord::Base.transaction(requires_new: true) do
            self.class.lock(@signature)
            @submission.lock!
            next result(false, :aborted, nil, false) unless @submission.in_progress?
            next result(true, :resumed, @submission.book, @submission.created_book?) if @submission.book
            next result(false, :no_owner, nil, false) unless @submission.user_id && @submission.user_list_id

            racer = @match.matched? ? nil : book_created_since_the_finder_looked
            if racer
              @match.decision&.update!(record: racer)
              record(racer, created: false)
              result(true, :adopted, racer, false)
            elsif @match.matched?
              record(@match.record, created: false)
              result(true, :matched, @match.record, false)
            else
              book = create
              record(book, created: true)
              result(true, :created, book, true)
            end
          end
        rescue NoAuthor => error
          Result.new(success?: false, data: {outcome: :no_author}, errors: [error.message])
        end

        private

        def book_created_since_the_finder_looked
          considered = @match.candidates.select(&:local?).map { |candidate| candidate.record.id }
          submitted = ::Books::BookSubmission.where(signature: @signature, created_book: true)
            .where.not(id: @submission.id).where.not(book_id: [nil, *considered]).order(:id).first&.book
          submitted || ::Books::GoodreadsEdition.created.where(signature: @signature)
            .where.not(book_id: [nil, *considered]).order(:resolved_at, :id).first&.book
        end

        def create
          identifiers = @resolved[:identifiers]
          result = @importer.call(
            title: @title, subtitle: @resolved[:subtitle], author_names: @author_names, year: @resolved[:year],
            isbn13: identifiers[:isbn13], isbn10: identifiers[:isbn10], asin: identifiers[:asin],
            goodreads_id: identifiers[:goodreads_id], subject: @submission, match: @match,
            provisional: true, stamp_identifiers: true, enrich: false, query_identifier_source: :user_submission
          )
          book = result.item
          unless result.created? && book&.persisted?
            raise CreateFailed, "no book created for submission #{@submission.id}: #{result.all_errors.join("; ")}"
          end
          raise NoAuthor, "the book for submission #{@submission.id} got no author" unless ::Books::BookAuthor.exists?(book: book)

          book
        end

        def record(book, created:)
          @submission.update!(book: book, created_book: created, match_decision: @match.decision, signature: @signature,
            resolved_title: @title, resolved_author_names: @author_names, review_status: created ? :pending : :not_needed)
        end

        def result(success, outcome, book, created)
          Result.new(success?: success, data: {outcome: outcome, book: book, created: created}, errors: [])
        end
      end
    end
  end
end
