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
      # Amazon also writes "(Series Trilogy, 1)" and "(Series, Book One)": a bare
      # trailing number, or a spelled-out one, each with no range after it.
      NUMBER_WORDS = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
      SINGLE_BOOK_MARKER = /
        (?:\b(?:book|vol(?:ume)?\.?)|\#)\s*\d+\b(?!\s*(?:-|–|to|through|and|&)\s*\d)
        | ,\s*\d+\s*[)\]]
        | \b(?:book|vol(?:ume)?\.?)\s+(?:#{NUMBER_WORDS})\b(?!\s*(?:-|–|to|through|and|&)\s*\w)
      /xi
      # A "#1-3" range anywhere is a set. Kept here, never in the shared SET_WORDS.
      NUMBER_RANGE = /#\s*\d+\s*(?:-|–|to|through)\s*\d+/i
      # Series-name words a single-book marker bracket forgives; any other set
      # word in that bracket ("Box Set", "Omnibus", "4-Book") still counts.
      SERIES_NAME_WORDS = ["trilogy", "collection", "volumes", "complete series"].freeze
      # Adaptations and study aids are other books, not editions of this one.
      DERIVATIVE_WORDS = /\b(?:graphic novels?|adaptation|adapted|young readers|young adult adaptation|abridged|retold|retelling|colou?ring book|study guide|summary|summaries|workbook|companion|manga|sparknotes|cliffsnotes)\b/i
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
      # Book 1)" is a series marker on one book, so a bracket holding a
      # single-book marker forgives its series-name words only ("Box Set" there
      # still counts); a set word in the book's own title ("Collection of Sand")
      # is not evidence of a set.
      def set?(book, product)
        return true if product.dig("itemInfo", "classifications", "binding", "displayValue").to_s.match?(/\bbox/i)

        raw = product.dig("itemInfo", "title", "displayValue").to_s
        return true if raw.match?(NUMBER_RANGE)

        text = raw.gsub(BRACKETED) { |part| part.match?(SINGLE_BOOK_MARKER) ? " #{(set_words(part) - SERIES_NAME_WORDS).join(" ")} " : part }
        (set_words(text) - own_words(book, :set_words)).any?
      end

      # An adaptation, abridgement, study aid or colouring book of the book. The
      # whole raw title is scanned, brackets included, and a term the book's own
      # title carries ("Maus: A Graphic Novel") does not count.
      def derivative?(book, product)
        raw = product.dig("itemInfo", "title", "displayValue").to_s
        (derivative_words(raw) - own_words(book, :derivative_words)).any?
      end

      # Exactly this book: not a set, a title our records agree with, not
      # published before the book, and an author the book shares.
      def same_book?(book, product)
        return false if set?(book, product) || derivative?(book, product)

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

      def own_words(book, scanner)
        ([book.title] + Array(book.alternate_titles)).flat_map { |title| send(scanner, title.to_s) }
      end

      def derivative_words(text)
        text.to_enum(:scan, DERIVATIVE_WORDS).map { Regexp.last_match(0).downcase }
      end

      def set_words(text)
        text.to_enum(:scan, Verification::EditionCheck::SET_WORDS).map { Regexp.last_match(0).downcase }
      end
    end
  end
end
