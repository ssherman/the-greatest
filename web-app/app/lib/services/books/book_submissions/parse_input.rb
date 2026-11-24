# frozen_string_literal: true

require "digest"
require "uri"

module Services
  module Books
    module BookSubmissions
      # Reads what a reader typed into the "Add a book" form and turns it into
      # the attributes of a Books::BookSubmission plus a fingerprint. Pure: no
      # database, no network, and a pasted link is never fetched, only read.
      #
      # `params` comes straight from the request, so any value can be nil, the
      # wrong type or invalid UTF-8. A value of the wrong type counts as blank;
      # invalid bytes are scrubbed. Nothing here raises.
      #
      # data[:attributes] holds only the keys the method may set, because the
      # model refuses the others. data[:fingerprint] is equal for equal
      # normalized input (the same Goodreads id from two URLs, an ISBN-10 and
      # its ISBN-13, title text differing in case or spacing) and different
      # between methods.
      class ParseInput
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        METHODS = %w[goodreads amazon isbn title_authors].freeze
        MAX_LINK = 2048
        MAX_LENGTH = ::Books::BookSubmission::MAX_LENGTH
        MAX_AUTHORS = ::Books::BookSubmission::MAX_AUTHORS

        # The form field each method reads, so a filled field belonging to a
        # different method can be refused.
        FIELDS = {
          "goodreads" => %i[goodreads_url],
          "amazon" => %i[amazon_url],
          "isbn" => %i[isbn],
          "title_authors" => %i[title authors]
        }.freeze

        AMAZON_HOST = /\A(?:www\.|smile\.|m\.)?amazon\.(?:com|ca|co\.uk|de|fr|it|es|nl|se|pl|ie|com\.au|com\.mx|com\.br|com\.be|com\.tr|co\.jp|in|sg|ae|sa|eg)\z/
        GOODREADS_PATH = %r{\A(?:/[a-z]{2}(?:-[a-z]+)?)?/book/show/(\d{1,18})(?:[-./]|\z)}i
        AMAZON_PATH = %r{/(?:dp|gp/product|gp/aw/d|exec/obidos/ASIN)/([A-Z0-9]{10})(?:[/?]|\z)}i

        GOODREADS_HELP = "Paste a Goodreads book link, like https://www.goodreads.com/book/show/13651"
        AMAZON_HELP = "Paste an Amazon book link that contains /dp/ or /gp/product/ and the product code"
        ISBN_HELP = "Enter a valid ISBN-10 or ISBN-13 (an ISBN-13 starts with 978 or 979)"

        def self.call(params)
          new(params).call
        end

        def initialize(params)
          @params = params
        end

        def call
          method = text(field(:method))
          return failure("Choose how you want to add the book.") unless METHODS.include?(method)

          others = (FIELDS.keys - [method]).flat_map { |name| FIELDS[name] }.select { |key| filled?(key) }
          return failure("Use one way to add a book at a time.") if others.any?

          send(:"parse_#{method}")
        end

        private

        def parse_goodreads
          link = link_for(:goodreads_url, GOODREADS_HELP) or return @failure
          uri = parse_uri(link)
          match = uri && goodreads_host?(uri.host) && GOODREADS_PATH.match(uri.path.to_s)
          return failure(GOODREADS_HELP) unless match

          id = match[1].to_i
          success({input_method: "goodreads", raw_input: link, goodreads_book_id: id}, ["goodreads", id])
        end

        def parse_amazon
          link = link_for(:amazon_url, AMAZON_HELP) or return @failure
          uri = parse_uri(link)
          match = uri && uri.host.to_s.downcase.match?(AMAZON_HOST) && AMAZON_PATH.match(uri.path.to_s)
          return failure(AMAZON_HELP) unless match

          asin = match[1].upcase
          attributes = {input_method: "amazon", raw_input: link, asin: asin}
          isbn = asin.match?(/\A\d{9}[\dX]\z/) ? ::Books::Isbn.normalize(asin) : nil
          attributes = attributes.merge(isbn13: isbn.isbn13, isbn10: isbn.isbn10) if isbn
          success(attributes, ["amazon", asin])
        end

        def parse_isbn
          raw = text(field(:isbn))
          return failure(ISBN_HELP) if raw.empty? || raw.length > MAX_LINK

          isbn = ::Books::Isbn.normalize(raw)
          return failure(ISBN_HELP) unless isbn&.isbn13&.match?(/\A97[89]/)

          attributes = {input_method: "isbn", raw_input: raw, isbn13: isbn.isbn13}
          attributes[:isbn10] = isbn.isbn10 if isbn.isbn10
          success(attributes, ["isbn", isbn.isbn13])
        end

        def parse_title_authors
          title = squish(field(:title))
          authors = author_values.map { |name| squish(name) }.reject(&:empty?)
          errors = []
          errors << "Enter the book's title." if title.empty?
          errors << "The title can be at most #{MAX_LENGTH} characters." if title.length > MAX_LENGTH
          errors << "Enter at least one author." if authors.empty?
          errors << "Enter at most #{MAX_AUTHORS} authors." if authors.size > MAX_AUTHORS
          errors << "Each author name can be at most #{MAX_LENGTH} characters." if authors.any? { |name| name.length > MAX_LENGTH }
          return Result.new(success?: false, data: nil, errors: errors) if errors.any?

          success({input_method: "title_authors", typed_title: title, typed_author_names: authors},
            ["title_authors", title.downcase, authors.map(&:downcase)])
        end

        def link_for(key, help)
          link = text(field(key))
          if link.empty? || link.length > MAX_LINK
            @failure = failure(help)
            return nil
          end
          link
        end

        # A link with no scheme is read as https. A string that cannot be
        # parsed, or that is not http(s), is refused by the caller.
        def parse_uri(link)
          candidate = link.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? link : "https://#{link}"
          uri = URI.parse(candidate)
          (uri.is_a?(URI::HTTP) && uri.host.present?) ? uri : nil
        rescue URI::Error
          nil
        end

        def goodreads_host?(host)
          host = host.to_s.downcase
          host == "goodreads.com" || host.end_with?(".goodreads.com")
        end

        def author_values
          value = field(:authors)
          value.is_a?(Array) ? value.select { |name| name.is_a?(String) } : []
        end

        def filled?(key)
          value = field(key)
          if key == :authors
            author_values.any? { |name| !text(name).empty? }
          else
            !text(value).empty?
          end
        end

        def field(key)
          return nil unless @params.is_a?(Hash) || @params.is_a?(ActionController::Parameters)

          value = @params[key]
          value = @params[key.to_s] if value.nil? && @params.is_a?(Hash)
          value
        end

        # Strings only; invalid bytes scrubbed, NULs dropped, ends trimmed
        # (including Unicode spaces).
        def text(value)
          return "" unless value.is_a?(String)

          value.dup.force_encoding(Encoding::UTF_8).scrub("").delete("\u0000").gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
        end

        def squish(value)
          text(value).gsub(/[[:space:]]+/, " ")
        end

        def success(attributes, fingerprint_parts)
          Result.new(
            success?: true,
            data: {attributes: attributes, fingerprint: Digest::SHA256.hexdigest(JSON.generate(fingerprint_parts))},
            errors: []
          )
        end

        def failure(message)
          Result.new(success?: false, data: nil, errors: [message])
        end
      end
    end
  end
end
