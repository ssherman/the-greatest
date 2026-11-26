# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # The title of a book made from a Goodreads title: the closing series or
      # format note is left off ("BOOM goes the Bride (Brides of Nap City Book
      # 1)"), unless the author already has a book under what is left, which the
      # note then tells apart.
      #
      # The title is never split into title and subtitle here. Replayed on
      # production (2026-11-25), splitting stored "Dune" / "A Whisper of Caladan
      # Seas" and "Batman" / "The Knight": the next plain "Dune" or "Batman" by
      # that author would match it by rule. Whole, it cannot, and the finder
      # matches a whole title to a split one anyway.
      #
      # The edition's own title, its signature and the finder's query keep the
      # export's title as it came.
      class BookTitle
        def self.call(text:, author_names:) = new(text, author_names).call

        def initialize(text, author_names)
          @text = text
          @author_names = Array(author_names)
        end

        def call
          noteless = ::DataImporters::Books::Book::TitleForms.without_note(@text)
          (noteless == @text || taken?(noteless)) ? @text : noteless
        end

        private

        def taken?(title)
          keys = ::Services::Text::PersonNameKey.all(@author_names)
          return false if keys.empty?

          ::Books::Book.joins(book_authors: :author)
            .where("books_authors.name_keys && ARRAY[:keys]::varchar[]", keys: keys)
            .exists?(["LOWER(books_books.title) = ?", key(title)])
        end

        def key(title)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(title)).downcase
        end
      end
    end
  end
end
