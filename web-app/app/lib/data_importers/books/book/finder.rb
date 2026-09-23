# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Finds an existing ::Books::Book before import and answers with a
      # Match (see FinderBase).
      #
      # Increment 1: the pre-redesign lookup -- identifiers first (Open
      # Library work key, ISBN-13, ISBN-10, ASIN, Goodreads id), then an exact
      # title+author match -- runs as the single decisive source, so behaviour
      # is unchanged. Increment 2 replaces it with the identifier, exact,
      # OpenSearch and Open Library sources.
      #
      # Never calls the Open Library service (or any other external API).
      class Finder < DataImporters::FinderBase
        protected

        def model_class = ::Books::Book

        def ranking_configuration_class = ::Books::RankingConfiguration

        def candidate_sources(query)
          [DataImporters::Sources::Legacy.new { legacy_lookup(query) }]
        end

        private

        def legacy_lookup(query)
          find_by_identifiers(query) || find_by_title_and_author(query)
        end

        def find_by_identifiers(query)
          if query.open_library_work_key.present?
            found = find_by_identifier(
              identifier_type: :books_work_openlibrary_id,
              identifier_value: query.open_library_work_key,
              model_class: ::Books::Book
            )
            return found if found
          end

          found = find_by_identifier_values(:books_work_isbn13, query.isbn13)
          return found if found

          found = find_by_identifier_values(:books_work_isbn10, query.isbn10)
          return found if found

          found = find_by_identifier_values(:books_work_asin, query.asin)
          return found if found

          find_by_identifier_values(:books_work_goodreads_id, query.goodreads_id)
        end

        def find_by_identifier_values(identifier_type, values)
          values.each do |value|
            found = find_by_identifier(identifier_type: identifier_type, identifier_value: value, model_class: ::Books::Book)
            return found if found
          end

          nil
        end

        def find_by_title_and_author(query)
          return nil if query.title.blank? || query.author_names.empty?

          normalized_title = ::Services::Text::QuoteNormalizer.call(query.title)

          ::Books::Book
            .joins(book_authors: :author)
            .where("LOWER(books_books.title) = LOWER(?)", normalized_title)
            .where("LOWER(books_authors.name) IN (?)", query.author_names.map(&:downcase))
            .first
        end
      end
    end
  end
end
