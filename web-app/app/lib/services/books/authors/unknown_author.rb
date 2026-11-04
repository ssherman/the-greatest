# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The one author a book with no known author is credited to. The catalog
      # uses an author named "Unknown" for these (The Bible, anonymous folk
      # tales), and imports used to create a fresh "Anonymous" or "Unknown
      # Author" each time. Every such name now means this one author.
      #
      # "Various" (an anthology byline) and place names used as authors
      # ("China" for the I Ching) are not placeholders: they say something
      # different and stay separate.
      module UnknownAuthor
        CANONICAL_NAME = "Unknown"
        PLACEHOLDER_NAMES = ["unknown", "unknown author", "anonymous", "anon"].freeze

        module_function

        def placeholder?(name)
          PLACEHOLDER_NAMES.include?(normalize(name))
        end

        # The author named exactly "Unknown" that holds the most books, lowest
        # id on a tie, so the rule picks the same record before and after a
        # merge without a hardcoded id that differs between databases.
        def canonical
          ::Books::Author.where(name: CANONICAL_NAME)
            .left_joins(:book_authors).group(:id)
            .order(Arel.sql("COUNT(books_book_authors.id) DESC"), :id)
            .first
        end

        # The database only narrows the candidates; `placeholder?` decides, so
        # the merge and the finder can never disagree about a name.
        def placeholders
          ids = ::Books::Author.where("name ILIKE '%unknown%' OR name ILIKE '%anon%'").pluck(:id, :name)
            .filter_map { |id, name| id if placeholder?(name) }
          ::Books::Author.where(id: ids)
        end

        # Whitespace collapsed (tabs, newlines and no-break spaces too), one
        # trailing period dropped, lowercased.
        def normalize(name)
          name.to_s.gsub(/[[:space:]]+/, " ").strip.delete_suffix(".").strip.downcase
        end
      end
    end
  end
end
