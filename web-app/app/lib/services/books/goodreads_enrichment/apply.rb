# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # Applies one confirmed Goodreads page to a book and records one ledger row. Fill
      # blanks only, never refill a human-cleared field, never write the description,
      # never create a category. Idempotent: a backfill re-runs it over cached pages, and
      # the second run records nothing_to_apply with every fact already_set.
      #
      # Spec: docs/superpowers/specs/2026-10-25-books-goodreads-enrichment-design.md §5, §10.
      class Apply
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        KIND = "books.goodreads"
        NOT_PAGES = /audio|kindle|ebook|e-book/i
        ASIN = /\A[A-Z0-9]{10}\z/
        GOODREADS_ID = "books_work_goodreads_id"

        def self.call(book:, page:)
          new(book: book, page: page).call
        end

        def initialize(book:, page:)
          @book = book
          @page = page
          @facts = {}
          @applied = []
          @matcher = GenreMatcher.new
        end

        def call
          enrichment = ::Books::Book.transaction do
            @cleared = HumanClearedFields.for(@book)
            apply_year
            apply_pages
            @book.save! if @book.changed?
            apply_genres
            apply_series
            apply_identifiers
            record_ledger
          end
          Result.new(success?: true, data: {enrichment: enrichment, applied: @applied}, errors: [])
        end

        private

        def fact(applied, reason, value) = {"value" => value, "applied" => applied, "reason" => reason}

        def apply_year
          value = @page.original_publication_year
          @facts["first_published_year"] =
            if value.nil? then fact(false, "null", nil)
            elsif @cleared.include?("first_published_year") then fact(false, "human_cleared", value)
            elsif @book.first_published_year.present? then fact(false, "already_set", value)
            else
              @book.first_published_year = value
              @applied << "first_published_year"
              fact(true, "filled", value)
            end
        end

        # An audiobook's or ebook's length is not the book's page count. The default
        # edition's count is filled under the same condition as the work's range.
        def apply_pages
          value = @page.page_count
          return @facts["page_range"] = fact(false, "null", nil) if value.nil? || value <= 0

          text = value.to_s
          return @facts["page_range"] = fact(false, "format_not_paged", text) if @page.format.to_s.match?(NOT_PAGES)
          return @facts["page_range"] = fact(false, "human_cleared", text) if @cleared.include?("page_range")
          return @facts["page_range"] = fact(false, "already_set", text) if @book.page_range.present?

          @book.page_range = text
          edition = @book.default_edition
          edition_filled = edition.present? && edition.page_count.blank?
          edition.update!(page_count: value) if edition_filled
          @applied << "page_range"
          @facts["page_range"] = fact(true, "filled", text).merge("edition_page_count_filled" => edition_filled)
        end

        def apply_genres
          type_names = ::Books::Book::BOOK_TYPE_CATEGORY_NAMES
          matched = Array(@page.genres).map { |name| [name, @matcher.match(name)] }
          page_types = matched.filter_map { |_, category| category&.name if type_names.include?(category&.name) }.uniq
          both_types = page_types.size == type_names.size

          entries = []
          unmatched = []
          matched.each do |name, category|
            if category.nil?
              unmatched << name
              entries << {"value" => name, "applied" => false, "reason" => "no_match", "category_id" => nil}
              next
            end
            applied, reason = link_category(category, both_types)
            @applied << "genres" if applied && !@applied.include?("genres")
            entries << {"value" => name, "applied" => applied, "reason" => reason, "category_id" => category.id}
          end
          @facts["genres"] = {"entries" => entries, "unmatched" => unmatched}
        end

        # Fiction and Nonfiction exclude each other: a book holding one never takes the
        # other, and a page claiming both says nothing about which is right.
        def link_category(category, both_types)
          return [false, "already_set"] if ::CategoryItem.exists?(category: category, item: @book)

          type_names = ::Books::Book::BOOK_TYPE_CATEGORY_NAMES
          if type_names.include?(category.name)
            held = @book.categories.where(name: type_names).pluck(:name)
            return [false, "type_conflict"] if (held - [category.name]).any? || (both_types && held.empty?)
          end

          ::CategoryItem.find_or_create_by!(category: category, item: @book) { |link| link.source = :goodreads }
          [true, "filled"]
        end

        def apply_series
          series = ApplySeries.call(book: @book, entries: @page.series)
          @facts["series"] = series
          @applied << "series" if series.any? { |f| f["applied"] }
        end

        def apply_identifiers
          entries = []
          goodreads = [GOODREADS_ID, @page.goodreads_book_id.to_s]
          isbn_pairs, invalid = isbn_and_asin_pairs

          invalid.each { |type, value| entries << identifier_fact(type, value, false, "invalid") }

          if holder_ids.any?
            flag_goodreads_holders
            ([goodreads] + isbn_pairs).each { |type, value| entries << identifier_fact(type, value, false, "collision") }
          else
            entries.concat(write([goodreads]))
            entries.concat(write(isbn_pairs))
          end
          @facts["identifiers"] = entries
          @applied << "identifiers" if entries.any? { |e| e["applied"] }
        end

        def write(pairs)
          return [] if pairs.empty?

          existing = pairs.select { |type, value| @book.identifiers.exists?(identifier_type: type, value: value) }
          result = BookIdentifierWriter.call(book: @book, pairs: pairs, source: :goodreads,
            evidence: {"goodreads_book_id" => @page.goodreads_book_id})
          pairs.map do |pair|
            if result.written.empty? then identifier_fact(*pair, false, "collision")
            elsif existing.include?(pair) then identifier_fact(*pair, false, "already_set")
            else
              identifier_fact(*pair, true, "filled")
            end
          end
        end

        def identifier_fact(type, value, applied, reason)
          {"type" => type, "value" => value, "applied" => applied, "reason" => reason}
        end

        # Returns [pairs to write, [[type, value]] that failed a check].
        def isbn_and_asin_pairs
          pairs = []
          invalid = []
          [["books_work_isbn13", @page.isbn13], ["books_work_isbn10", @page.isbn10]].each do |type, raw|
            next if raw.blank?

            normalized = ::Books::Isbn.normalize(raw)
            if normalized
              pairs << ["books_work_isbn13", normalized.isbn13]
              pairs << ["books_work_isbn10", normalized.isbn10] if normalized.isbn10
            else
              invalid << [type, raw]
            end
          end

          asin = @page.asin.to_s.strip.upcase
          if asin.present?
            valid = asin.match?(/\A\d+\z/) ? (asin.length == 10 && ::Books::Isbn.normalize(asin).present?) : asin.match?(ASIN)
            valid ? pairs << ["books_work_asin", asin] : invalid << ["books_work_asin", asin]
          end
          [pairs.uniq, invalid]
        end

        # Any source: an unverified holder is as likely right as we are, so the two
        # books go to a human instead of one of them silently keeping the id.
        def holder_ids
          @holder_ids ||= ::Identifier.where(identifiable_type: "Books::Book", identifier_type: GOODREADS_ID,
            value: @page.goodreads_book_id.to_s).where.not(identifiable_id: @book.id).pluck(:identifiable_id).uniq
        end

        def flag_goodreads_holders
          holder_ids.each do |holder_id|
            ::Services::DuplicateCandidates::Flag.call(
              item_type: "Books::Book", ids: [@book.id, holder_id], source: :identifier_collision,
              evidence: {"goodreads_book_id" => @page.goodreads_book_id, "holder_book_id" => holder_id},
              match_decision: nil
            )
          end
        end

        def record_ledger
          @book.enrichments.create!(
            kind: KIND, provider: "goodreads", recognized: true,
            citations: ["https://www.goodreads.com/book/show/#{@page.goodreads_book_id}"],
            outcome: @applied.any? ? :applied : :nothing_to_apply,
            facts: @facts
          )
        end
      end
    end
  end
end
