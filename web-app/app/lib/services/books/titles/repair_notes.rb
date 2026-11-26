# frozen_string_literal: true

module Services
  module Books
    module Titles
      # A one-off repair of titles imported from Goodreads, Amazon and the legacy
      # app (2026-11-25):
      #
      # - a title cut at a colon inside its brackets ("Accounting 2 (Quick Study"
      #   / "Business)", 72 books, from the Goodreads rebuild's fix_identity) is
      #   joined back up;
      # - a closing series or format note ("(Brides of Nap City Book 1)", "(Spanish
      #   Edition)") comes off the title and the subtitle, by TitleForms' rules,
      #   unless the author already has another book under the shorter title.
      #
      # Any other bracket stays, for a person or an agent to judge. Matching is
      # unaffected: the finder compares titles without such notes. A second run
      # changes nothing. Slugs stay.
      class RepairNotes
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        CANDIDATES = <<~SQL.squish
          books_books.title ~ '[)\\]]\\s*$' OR books_books.subtitle ~ '[)\\]]\\s*$'
          OR (books_books.title ~ '[(\\[][^)\\]]*$' AND books_books.subtitle ~ '^[^(\\[]*[)\\]]')
        SQL
        CUT_OPEN = /[(\[][^)\]]*\z/
        CUT_CLOSE = /\A[^(\[]*[)\]]/

        def self.call(dry_run: false) = new(dry_run).call

        def initialize(dry_run)
          @dry_run = dry_run
        end

        def call
          changes = []
          ::Books::Book.where(CANDIDATES).includes(:book_authors).find_each do |book|
            title, subtitle = repaired(book)
            next if [title, subtitle] == [book.title, book.subtitle]

            changes << {id: book.id, from: [book.title, book.subtitle], to: [title, subtitle]}
            book.update!(title: title, subtitle: subtitle) unless @dry_run
          end
          Result.new(success?: true, data: {changed: changes.size, changes: changes}, errors: [])
        end

        private

        def forms = ::DataImporters::Books::Book::TitleForms

        def repaired(book)
          title, subtitle = book.title, book.subtitle
          if title.match?(CUT_OPEN) && subtitle.to_s.match?(CUT_CLOSE)
            title, subtitle = forms.full(title, subtitle), nil
          end
          shorter = forms.without_note(title)
          title = shorter unless taken?(book, shorter)
          subtitle = forms.without_note(subtitle) if subtitle.present?
          [title, subtitle]
        end

        def taken?(book, title)
          ::Books::Book.joins(:book_authors).where(book_authors: {author_id: book.book_authors.map(&:author_id)})
            .where.not(id: book.id)
            .exists?(["LOWER(books_books.title) = ?", ::DataImporters::Books::Book::ExactLookup.key(title)])
        end
      end
    end
  end
end
