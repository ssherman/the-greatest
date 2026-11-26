# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Normalized title equality (served by the lower(title) expression
      # index), joined to an author whose name keys
      # (Services::Text::PersonNameKey, GIN-indexed books_authors.name_keys)
      # meet the query's when the query names authors. A title-only query still yields
      # title matches: they are candidates for the AI, never a rule-4
      # match, because creators_required? is true for books.
      #
      # The filtered ids are plucked first, with no ORDER BY or LIMIT on
      # the filtered query: measured on 158k books, ORDER BY id + LIMIT 5
      # on the filtered relation makes the planner walk the primary key
      # (59 ms, every row filtered) instead of using
      # index_books_books_on_lower_title (0.01 ms). A title matches a
      # handful of rows, so plucking them all is cheap.
      #
      # With authors, the title also reaches books that hold it split or whole
      # ("Andrew Johnson: A Biography" against "Andrew Johnson" / "A Biography"),
      # without a closing series note (TitleForms). Those whole-title matches come
      # first, so a long series cannot push one out of the limit. loose: also
      # books that share only the part before the colon, which the finder offers
      # the AI and never matches by rule.
      #
      # Shared by the finder's exact source and the book-submission instant
      # check, which must not leave Postgres.
      class ExactLookup
        def self.call(title:, author_names:, subtitle: nil, limit: 5, loose: false)
          new(title, subtitle, author_names, limit, loose).call
        end

        # The normalized whole titles a title (and subtitle) stand for, with and
        # without a closing note.
        def self.whole_keys(title, subtitle = nil)
          [title, TitleForms.without_note(title)]
            .flat_map { |form| [key(form), key(TitleForms.full(form, subtitle))] }.compact_blank.uniq
        end

        def self.key(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
        end

        def initialize(title, subtitle, author_names, limit, loose)
          @title = title
          @subtitle = subtitle
          @author_names = author_names
          @limit = limit
          @loose = loose
        end

        def call
          return ::Books::Book.none if @title.blank?

          keys = ::Services::Text::PersonNameKey.all(@author_names)
          filtered = ::Books::Book.where("LOWER(books_books.title) IN (?)", keys.any? ? titles : [self.class.key(@title)])
          if keys.any?
            filtered = filtered.joins(book_authors: :author)
              .where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
          end
          rows = filtered.distinct.pluck(:id, :title, :subtitle)
          whole = self.class.whole_keys(@title, @subtitle)
          ids = rows.select { |_, title, subtitle| @loose || keys.empty? || whole?(whole, title, subtitle) }
            .sort_by { |id, title, subtitle| [whole?(whole, title, subtitle) ? 0 : 1, id] }.map(&:first).first(@limit)
          ::Books::Book.where(id: ids).includes(:authors, :identifiers).order(:id)
        end

        private

        # Every title our title column may hold for this book.
        def titles
          heads = [@title, TitleForms.without_note(@title)].map { |form| TitleForms.split(form).first }
          heads << TitleForms.main(@title) if @loose
          (self.class.whole_keys(@title, @subtitle) + heads.map { |head| self.class.key(head) }).uniq
        end

        def whole?(whole, title, subtitle)
          ([self.class.key(title), self.class.key(TitleForms.full(title, subtitle))] & whole).any?
        end
      end
    end
  end
end
