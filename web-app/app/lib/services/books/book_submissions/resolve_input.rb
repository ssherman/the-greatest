# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Turns a persisted submission's input into a title and authors. It runs
      # inside a Sidekiq job, never in a web request, and it only reports
      # facts: it creates no book, queues no job and fetches no Goodreads page
      # (the job does, on :needs_goodreads_page).
      #
      # data[:outcome] is one of
      #   :resolved              title, subtitle, author_names, year, identifiers, source
      #   :needs_goodreads_page  a Goodreads link whose page is not cached yet
      #   :no_record             every source answered and none had the book
      #   :unavailable           nothing was usable and at least one source raised
      #
      # Sources in order: the supplied facts, then by input method (goodreads;
      # amazon, with the isbn chain after it when Amazon has nothing usable;
      # isbn: WorldCat, Open Library, Amazon; title_authors as typed). The
      # first usable answer wins. A definite "no such record" (a 404) is an
      # answer, not a failure. A source that is down is skipped, and the
      # outcome is :unavailable only when nothing else was usable.
      #
      # What it returns becomes the finder query and the new book, so an
      # identifier is returned only when the submission itself carried it,
      # never one found on a record.
      #
      # Errors: the lookup clients' own errors, Amazon's and the transport
      # errors that can escape them count as "that source raised". Database
      # errors and programming errors propagate; the job fails loudly rather
      # than reporting a bug as a source being down.
      #
      # `lookup` on the submission is replaced each run with one entry per
      # source tried; no other column is written.
      class ResolveInput
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        SOURCE_ERRORS = [
          ::Books::WorldCat::Exceptions::Error, ::Books::OpenLibrary::Exceptions::Error,
          ::Services::Amazon::Client::Error, ::HTTP::Error, ::Timeout::Error, ::SocketError,
          ::SystemCallError, ::OpenSSL::SSL::SSLError, ::JSON::ParserError
        ].freeze
        IDENTIFIER_KEYS = %w[isbn13 isbn10 asin goodreads_id].freeze
        MAX_IDENTIFIERS = 10
        MAX_ERROR_MESSAGE = 500

        def self.call(submission:)
          new(submission).call
        end

        def initialize(submission)
          @submission = submission
          @entries = []
          @raised = false
        end

        def call
          result = from_supplied || from_method
          submission.update_column(:lookup, entries)
          result
        end

        private

        attr_reader :submission, :entries

        def from_supplied
          supplied = submission.supplied
          return unless supplied.is_a?(Hash) && supplied.present?

          answer = Lookups::Answer.build(title: supplied["title"], subtitle: supplied["subtitle"],
            author_names: supplied["author_names"], year: supplied["year"])
          return unless answer.usable?

          record("supplied", answer)
          resolved(answer, "supplied", supplied_identifiers(supplied["identifiers"]))
        end

        def from_method
          case submission.input_method
          when "goodreads" then from_goodreads
          when "amazon" then first_usable(amazon_sources + isbn_sources)
          when "isbn" then first_usable(isbn_sources)
          else from_typed
          end
        end

        def from_typed
          answer = Lookups::Answer.build(title: submission.typed_title, author_names: submission.typed_author_names)
          record("title_authors", answer)
          answer.usable? ? resolved(answer, "title_authors", no_identifiers) : outcome(:no_record)
        end

        def from_goodreads
          page = ::Books::GoodreadsPage.conclusive.find_by(goodreads_book_id: submission.goodreads_book_id)
          if page.nil?
            entries << {"source" => "goodreads", "outcome" => "needs_page"}
            return outcome(:needs_goodreads_page)
          end

          contributors = page.contributors
          creators = contributors.select(&:creator?)
          names = (creators.presence || contributors).map(&:name)
          answer = page.outcome_found? ? Lookups::Answer.build(title: page.title, author_names: names, year: page.original_publication_year) : nil
          record("goodreads", answer&.usable? ? answer : nil)
          answer&.usable? ? resolved(answer, "goodreads", own_identifiers) : outcome(:no_record)
        end

        def amazon_sources
          [["amazon", -> { Lookups::Amazon.by_asin(submission.asin) }]]
        end

        def isbn_sources
          isbn13 = submission.isbn13
          return [] if isbn13.blank?

          [
            ["worldcat", -> { Lookups::WorldCat.call(isbn13) }],
            ["open_library", -> { Lookups::OpenLibrary.call(isbn13) }],
            ["amazon", -> { Lookups::Amazon.by_isbn(isbn13) }]
          ]
        end

        def first_usable(sources)
          sources.each do |source, lookup|
            answer = attempt(source, &lookup)
            return resolved(answer, source, own_identifiers) if answer
          end
          outcome(@raised ? :unavailable : :no_record)
        end

        # Runs one source: its answer, or nil when it had nothing usable or
        # raised. Either way what it said is recorded.
        def attempt(source)
          answer = yield
          record(source, answer)
          answer
        rescue *SOURCE_ERRORS => error
          @raised = true
          entries << {"source" => source, "outcome" => "error", "error_class" => error.class.name,
                      "error_message" => error.message.to_s.first(MAX_ERROR_MESSAGE)}
          nil
        end

        def record(source, answer)
          entries << if answer
            {"source" => source, "outcome" => "resolved", "title" => answer.title,
             "author_names" => answer.author_names, "year" => answer.year}.compact
          else
            {"source" => source, "outcome" => "empty"}
          end
        end

        def resolved(answer, source, identifiers)
          Result.new(success?: true, errors: [], data: {
            outcome: :resolved, source: source, title: answer.title, subtitle: answer.subtitle,
            author_names: answer.author_names, year: answer.year, identifiers: identifiers
          })
        end

        def outcome(name)
          return Result.new(success?: true, data: {outcome: name}, errors: []) unless name == :unavailable

          Result.new(success?: false, data: {outcome: name}, errors: ["No lookup source was available"])
        end

        def no_identifiers
          IDENTIFIER_KEYS.to_h { |key| [key.to_sym, []] }
        end

        # Only what the submission itself carried.
        def own_identifiers
          {
            isbn13: Array(submission.isbn13.presence), isbn10: Array(submission.isbn10.presence),
            asin: Array(submission.asin.presence), goodreads_id: Array(submission.goodreads_book_id&.to_s)
          }
        end

        def supplied_identifiers(raw)
          raw = {} unless raw.is_a?(Hash)
          IDENTIFIER_KEYS.to_h do |key|
            values = Array(raw[key]).filter_map { |value| Lookups::Names.text(value) }.uniq.first(MAX_IDENTIFIERS)
            [key.to_sym, values]
          end
        end
      end
    end
  end
end
