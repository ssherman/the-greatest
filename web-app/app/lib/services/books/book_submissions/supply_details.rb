# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # An agent or an admin supplies what a request that found no book was
      # missing: a title, authors and identifiers. Only while no book exists
      # (needs_details, failed); after that `update_book` is the fix. The row
      # goes back to queued with its counters and lease reset (Requeue), and the
      # lookup job runs again, reading `supplied` before the reader's own input
      # (ResolveInput#from_supplied).
      #
      # Nothing is stored raw. The title and names are scrubbed and squished and
      # obey the limits of the reader's form. Identifiers are normalized:
      # ISBNs by Books::Isbn (each stored with its other form), the Goodreads id
      # by Books::GoodreadsId, an ASIN by its ten-character format; a value that
      # fails is refused with the key named. `supplied` ends up as
      # {title, author_names, identifiers: {isbn13, isbn10, asin, goodreads_id}},
      # each identifier a list.
      class SupplyDetails
        Result = Lease::Result

        MAX_LENGTH = ::Books::BookSubmission::MAX_LENGTH
        MAX_AUTHORS = ::Books::BookSubmission::MAX_AUTHORS
        MAX_PER_KEY = 10
        KEYS = %w[isbn13 isbn10 asin goodreads_id].freeze
        ASIN = /\A[A-Z0-9]{10}\z/
        STATUSES = %w[needs_details failed].freeze
        # A reviewer on the admin page may also supply a row handed to a person; an agent may not.
        ADMIN_REVIEWS = %w[not_needed pending needs_human].freeze
        AGENT_REVIEWS = %w[not_needed pending].freeze

        def self.call(submission:, title:, author_names:, user:, via:, note:, identifiers: {}, lease_token: nil)
          new(submission: submission, title: title, author_names: author_names, identifiers: identifiers, user: user, via: via,
            note: note, lease_token: lease_token).call
        end

        # Whether the admin page may offer this row the form: no book, still waiting for details,
        # and a review state the admin path takes. Read from a loaded row.
        def self.available?(row) = row.book_id.nil? && STATUSES.include?(row.status) && ADMIN_REVIEWS.include?(row.review_status)

        def initialize(submission:, title:, author_names:, identifiers:, user:, via:, note:, lease_token:)
          @submission = submission
          @title = title
          @author_names = author_names
          @identifiers = identifiers
          @user = user
          @via = Lease.via!(via)
          @note = note
          @token = lease_token
        end

        def call
          row = ::Books::BookSubmission.find_by(id: @submission.id)
          refusal = row.nil? ? Lease.failure(:conflict, "the submission no longer exists") : state_failure(row)
          refusal ||= Lease.lease_failure(row, @token, @via)
          refusal ||= Lease.input_failure(note: @note, sources: [])
          return refusal if refusal

          supplied = build
          return supplied if supplied.is_a?(Result)

          scope = Lease.guard(::Books::BookSubmission.where(book_id: nil, status: STATUSES, review_status: reviews), @token, @via)
          changed = Requeue.call(scope, id: row.id, supplied: supplied, review_note: @note)
          return Lease.failure(:conflict, "the submission changed while the details were being supplied") if changed.zero?

          Lease.success(submission: ::Books::BookSubmission.find(row.id))
        end

        private

        def state_failure(row)
          return Lease.failure(:conflict, "the submission already has a book") if row.book_id
          return Lease.failure(:conflict, "the submission is #{row.status}, not waiting for details") unless STATUSES.include?(row.status)
          return Lease.failure(:conflict, "the submission is #{row.review_status}") unless reviews.include?(row.review_status)

          nil
        end

        # Reviews a request may be supplied in. The admin page may also take one
        # flagged needs_human (a skip, or abandoned by agents), which goes back
        # to not_needed; the API never holds a lease on it.
        def reviews = (@via == "admin_ui") ? ADMIN_REVIEWS : AGENT_REVIEWS

        # The stored hash, or a failed Result.
        def build
          title = squish(@title)
          return invalid("title must be 1 to #{MAX_LENGTH} characters") if title.empty? || title.length > MAX_LENGTH

          names = @author_names.is_a?(Array) ? @author_names.map { squish(it) } : nil
          if names.nil? || !names.size.between?(1, MAX_AUTHORS) || names.any? { it.empty? || it.length > MAX_LENGTH }
            return invalid("author_names must be 1 to #{MAX_AUTHORS} names of 1 to #{MAX_LENGTH} characters")
          end

          identifiers = normalize_identifiers
          return identifiers if identifiers.is_a?(Result)

          {"title" => title, "author_names" => names, "identifiers" => identifiers}
        end

        def normalize_identifiers
          return invalid("identifiers must be an object") unless @identifiers.is_a?(Hash) || @identifiers.respond_to?(:to_unsafe_h)

          given = (@identifiers.respond_to?(:to_unsafe_h) ? @identifiers.to_unsafe_h : @identifiers).stringify_keys
          unknown = given.keys - KEYS
          return invalid("identifiers has unknown key #{unknown.first.to_s.first(40)}") if unknown.any?

          found = KEYS.index_with { [] }
          KEYS.each do |key|
            values = Array(given[key]).compact
            return invalid("#{key} takes at most #{MAX_PER_KEY} values") if values.size > MAX_PER_KEY

            values.each do |value|
              return invalid("#{key} is not valid") unless add(found, key, value)
            end
          end
          found.transform_values(&:uniq)
        end

        # Adds a normalized value (an ISBN also adds its other form); false when it is not one.
        def add(found, key, value)
          raw = scrub(value.to_s)
          case key
          when "isbn13", "isbn10"
            isbn = ::Books::Isbn.normalize(raw)
            return false unless isbn

            found["isbn13"] << isbn.isbn13
            found["isbn10"] << isbn.isbn10 if isbn.isbn10
          when "asin"
            asin = raw.strip.upcase
            return false unless asin.match?(ASIN)

            found["asin"] << asin
          else
            id = ::Books::GoodreadsId.normalize(raw)
            return false unless id

            found["goodreads_id"] << id
          end
          true
        end

        def scrub(text) = text.dup.force_encoding(Encoding::UTF_8).scrub("").delete("\u0000")

        def squish(value)
          return "" unless value.is_a?(String)

          scrub(value).gsub(/[[:space:]]+/, " ").strip
        end

        def invalid(detail) = Lease.failure(:invalid, detail)
      end
    end
  end
end
