# frozen_string_literal: true

module Books
  module Goodreads
    # One row of a Goodreads library export, read by header name (Goodreads
    # import spec §4). Edition fields describe the edition the row names;
    # user fields are the member's shelves, rating, review and dates. A value
    # that does not parse is dropped and noted, never guessed; the notes end
    # up on the import row. Touches no database.
    class ExportRow
      PRIVATE_NOTES = "Private Notes"
      # Goodreads appends "(Series Name, #N)" to the title of every book in a
      # series. It is evidence, so it is kept, but it is not the title.
      SERIES_SUFFIX = /\A(?<title>.+?)\s*\((?<series>[^()#]+?),?\s*#(?<number>[^()]+)\)\s*\z/
      SHELF_POSITION = /\A(?<shelf>.+?)\s*\(#(?<position>\d+)\)\z/
      YEAR = /\A-?\d{1,4}\z/
      DATE_FORMAT = "%Y/%m/%d"

      attr_reader :row_number, :raw, :notes,
        :goodreads_book_id, :title, :series_name, :series_number, :primary_author, :additional_authors,
        :isbn13, :isbn10, :original_publication_year, :year_published, :publisher, :book_format, :pages,
        :exclusive_shelf, :shelves, :shelf_positions, :rating, :review_body, :date_read, :date_added, :read_count

      # The second half of an edition's key, and the advisory-lock key for
      # creating its book: the normalized title (series suffix removed) and
      # primary author. Honest exports give one title and author per Goodreads
      # id, so they share a signature; a row claiming a real id under another
      # title gets its own edition and cannot overwrite the honest one.
      def self.signature(title, primary_author)
        Digest::SHA256.hexdigest("#{normalize(title)}\u0000#{normalize(primary_author)}")
      end

      def self.normalize(text)
        ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
      end

      MISALIGNED = "columns do not line up with the header"

      # misaligned: the row's field count differs from the header's (a stray
      # quote split a field). Every value may sit under the wrong header --
      # Private Notes under My Review, a title under Author -- so none is
      # read or kept, not even raw.
      def initialize(row_number:, fields:, misaligned: false)
        @row_number = row_number
        @misaligned = misaligned
        @fields = misaligned ? {} : fields.to_h.reject { |header, _value| header.blank? }
        @raw = @fields.except(PRIVATE_NOTES)
        @notes = []
        parse
      end

      def errors
        return [MISALIGNED] if @misaligned

        [
          ("no Goodreads book id" if goodreads_book_id.nil?),
          ("no title" if title.blank?),
          ("no author" if primary_author.blank?)
        ].compact
      end

      def valid?
        errors.empty?
      end

      def signature
        self.class.signature(title, primary_author)
      end

      def edition_attributes
        {
          goodreads_book_id: goodreads_book_id, signature: signature, title: title,
          series_name: series_name, series_number: series_number, primary_author: primary_author,
          additional_authors: additional_authors, isbn13: isbn13, isbn10: isbn10,
          original_publication_year: original_publication_year, year_published: year_published,
          publisher: publisher, book_format: book_format, pages: pages
        }
      end

      def row_attributes
        {
          row_number: row_number, raw: raw, exclusive_shelf: exclusive_shelf, shelves: shelves,
          shelf_positions: shelf_positions, rating: rating, review_body: review_body,
          date_read: date_read, date_added: date_added, read_count: read_count, notes: notes
        }
      end

      private

      def parse
        @goodreads_book_id = ::Books::GoodreadsId.normalize(field("Book Id"))&.to_i
        split_title(clean(field("Title")))
        @primary_author = clean(field("Author"))
        @additional_authors = list(field("Additional Authors"))
        parse_isbns
        @original_publication_year = year("Original Publication Year")
        @year_published = year("Year Published")
        @publisher = clean(field("Publisher"))
        @book_format = clean(field("Binding"))
        @pages = integer("Number of Pages", minimum: 1)
        @exclusive_shelf = clean(field("Exclusive Shelf"))&.downcase
        @shelves = list(field("Bookshelves")).map(&:downcase).uniq
        @shelf_positions = shelf_positions_from(field("Bookshelves with positions"))
        @rating = integer("My Rating", minimum: 0, maximum: 5)
        @review_body = field("My Review").presence
        @date_read = date("Date Read")
        @date_added = date("Date Added")
        @read_count = integer("Read Count", minimum: 0)
      end

      def field(header)
        @fields[header].to_s
      end

      def clean(text)
        ::Services::Text::NameNormalizer.call(text.to_s).presence
      end

      def list(text)
        text.to_s.split(",").filter_map { |item| clean(item) }
      end

      def split_title(whole)
        match = whole && SERIES_SUFFIX.match(whole)
        if match && match[:title].strip.present?
          @title = match[:title].strip
          @series_name = match[:series].strip
          @series_number = match[:number].strip
        else
          @title = whole
        end
      end

      def parse_isbns
        from13 = isbn("ISBN13")
        from10 = isbn("ISBN")
        @isbn13 = from13&.isbn13 || from10&.isbn13
        @isbn10 = from10&.isbn10 || from13&.isbn10
      end

      def isbn(header)
        value = field(header)
        normalized = ::Books::Isbn.normalize(value)
        @notes << "invalid #{header} dropped: #{value}" if normalized.nil? && value.match?(/\d/)
        normalized
      end

      def year(header)
        value = field(header).strip
        return nil if value.empty?
        return value.to_i if value.match?(YEAR) && value.to_i != 0

        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end

      def integer(header, minimum:, maximum: nil)
        value = field(header).strip
        return nil if value.empty?

        number = Integer(value, 10, exception: false)
        return number if number && number >= minimum && (maximum.nil? || number <= maximum)

        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end

      def date(header)
        value = field(header).strip
        return nil if value.empty?

        Date.strptime(value, DATE_FORMAT)
      rescue Date::Error
        @notes << "unreadable #{header} dropped: #{value}"
        nil
      end

      def shelf_positions_from(text)
        list(text).each_with_object({}) do |entry, positions|
          match = SHELF_POSITION.match(entry)
          positions[match[:shelf].downcase] = match[:position].to_i if match
        end
      end
    end
  end
end
