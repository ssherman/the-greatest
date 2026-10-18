# frozen_string_literal: true

module Services
  module Books
    # The two deterministic questions the importer asks of an Amazon product:
    # is it a set (box set, omnibus, collection), and is it exactly this book,
    # so that its ISBNs may go on the book itself. Amazon search is fuzzy, so a
    # hit proves nothing alone. The rules are the verification pass's
    # (EditionCheck, Check), applied to an Amazon product instead of an Open
    # Library edition, so the two imports cannot drift on what a set is.
    module AmazonBookCheck
      module_function

      # Quack like an Open Library edition / work for EditionCheck and Check.
      Listing = Data.define(:title, :subtitle)
      Contributors = Data.define(:author_names, :author_keys)

      # One numbered book ("Book 1", "Vol. 2", "#3") names a single book; a
      # range ("Books 1-3") still names a set, so it is not a marker.
      SINGLE_BOOK_MARKER = /(?:\b(?:book|vol(?:ume)?\.?)|#)\s*\d+\b(?!\s*(?:-|–|to|through|and|&)\s*\d)/i
      BRACKETED = /[(\[][^()\[\]]*[)\]]/

      # Legacy's process_title: drop parenthesised and bracketed noise, then split
      # the first colon into title and subtitle. Loops to convergence because
      # nested brackets (e.g. "[Mass Market Paperback (2006)]") only expose their
      # outer pair once the innermost one has already been stripped.
      def split_title(raw)
        return [nil, nil] if raw.blank?

        cleaned = raw.dup
        loop do
          stripped = cleaned.gsub(/\s*[(\[][^()\[\]]*[)\]]\s*/, " ")
          break if stripped == cleaned
          cleaned = stripped
        end
        cleaned = cleaned.squeeze(" ").strip

        head, tail = cleaned.split(":", 2)
        [head&.strip.presence, tail&.strip.presence]
      end

      # A set word the product carries and the book does not. "(Tolstoy Trilogy,
      # Book 1)" is a series marker on one book, so brackets holding a
      # single-book marker are ignored; a set word in the book's own title
      # ("Collection of Sand") is not evidence of a set.
      def set?(book, product)
        return true if product.dig("itemInfo", "classifications", "binding", "displayValue").to_s.match?(/\bbox/i)

        raw = product.dig("itemInfo", "title", "displayValue").to_s
        text = raw.gsub(BRACKETED) { |part| part.match?(SINGLE_BOOK_MARKER) ? "" : part }
        ours = ([book.title] + Array(book.alternate_titles)).flat_map { |title| set_words(title.to_s) }
        (set_words(text) - ours).any?
      end

      # Exactly this book: not a set, a title our records agree with, not
      # published before the book, and an author the book shares.
      def same_book?(book, product)
        return false if set?(book, product)

        raw = product.dig("itemInfo", "title", "displayValue")
        listing = Listing.new(*split_title(raw))
        return false unless Verification::EditionCheck.title_agrees?(book, nil, listing)

        year = product.dig("itemInfo", "contentInfo", "publicationDate", "displayValue").to_s[/\A\d{4}/]
        return false unless Verification::EditionCheck.year_ok?(book, year)

        names = author_names(product)
        names.any? && Verification::Check.authors_agree?(book, Contributors.new(names, []))
      end

      def author_names(product)
        Array(product.dig("itemInfo", "byLineInfo", "contributors"))
          .select { |contributor| contributor["role"] == "Author" }
          .filter_map { |contributor| contributor["name"].presence }
      end

      def set_words(text)
        text.to_enum(:scan, Verification::EditionCheck::SET_WORDS).map { Regexp.last_match(0).downcase }
      end
    end
  end
end
