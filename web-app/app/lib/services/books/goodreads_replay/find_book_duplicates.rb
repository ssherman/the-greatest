# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.5, books. The replay's finder runs flag
      # suspected pairs into the duplicates queue. A pending pair becomes an
      # approved merge_books verdict only when all three hold:
      # - the normalized titles are equal;
      # - the author id sets are identical (and not empty);
      # - the two books share an identifier. With the same title and the same
      #   authors, that identifier is corroborated by construction.
      # The book kept is the one ranked first under the default configuration,
      # then the one on more curated lists, then the oldest. Every other pair
      # stays in the duplicates queue for an admin. Records findings only.
      class FindBookDuplicates
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        IDENTIFIER_TYPES = %w[books_work_isbn13 books_work_isbn10 books_work_goodreads_id books_work_asin books_work_openlibrary_id].freeze

        def self.call
          new.call
        end

        def call
          recorded = 0
          ::DuplicateCandidate.where(item_type: "Books::Book").pending.find_each do |pair|
            recorded += 1 if check(pair)
          end
          Result.new(success?: true, data: {recorded: recorded}, errors: [])
        end

        private

        def check(pair)
          books = ::Books::Book.where(id: [pair.item_a_id, pair.item_b_id]).includes(:identifiers, :book_authors).to_a
          return false unless books.size == 2

          a, b = books
          return false unless normalize(a.title) == normalize(b.title)

          authors = books.map { |book| book.book_authors.map(&:author_id).sort }
          return false if authors.first.empty? || authors.first != authors.last

          shared = identifiers(a) & identifiers(b)
          return false if shared.empty?

          target = preferred(books)
          source = (books - [target]).first
          RecordVerdict.call(
            kind: :merge_books, subject_key: "books:#{pair.item_a_id}:#{pair.item_b_id}",
            payload: {source_id: source.id, target_id: target.id, shared: shared.sort, duplicate_candidate_id: pair.id},
            decided_by: :rule, confidence: :certain, auto: true,
            reason: "same title and authors, and both hold #{shared.map { |type, value| "#{type} #{value}" }.join(", ")}"
          )
          true
        end

        def identifiers(book)
          book.identifiers.select { |identifier| IDENTIFIER_TYPES.include?(identifier.identifier_type) }
            .map { |identifier| [identifier.identifier_type, identifier.value] }
        end

        def preferred(books)
          ids = books.map(&:id)
          configuration = ::Books::RankingConfiguration.default_primary
          ranks = configuration ? ::RankedItem.where(ranking_configuration_id: configuration.id, item_type: "Books::Book", item_id: ids).pluck(:item_id, :rank).to_h : {}
          lists = ::ListItem.joins(:list).where(listable_type: "Books::Book", listable_id: ids, lists: {auto_generated_kind: nil})
            .group(:listable_id).count
          books.min_by { |book| [ranks.key?(book.id) ? 0 : 1, ranks[book.id].to_i, -lists.fetch(book.id, 0), book.id] }
        end

        def normalize(text)
          ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
        end
      end
    end
  end
end
