# frozen_string_literal: true

require "csv"

module Services
  module Books
    module WorldCat
      # Counts WorldCat genre terms across the records our ISBN-13s resolve to
      # and writes the head of the distribution for the mapping pass
      # (docs/superpowers/specs/2026-10-11-worldcat-data-service-design.md, "Vocabulary mapping").
      class VocabularySnapshot
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        HEAD_FILE = "genre_terms.csv"
        TAIL_FILE = "genre_terms_tail.csv"

        def self.call(client:, out_dir:, head_share: 0.98, batch_size: 500)
          new(client:, out_dir:, head_share:, batch_size:).call
        end

        def initialize(client:, out_dir:, head_share:, batch_size:)
          @client = client
          @out_dir = Pathname(out_dir)
          @head_share = head_share
          @batch_size = batch_size
        end

        def call
          uses = Hash.new(0)
          books_by_term = Hash.new { |h, k| h[k] = Set.new }
          books_seen = 0
          books_matched = 0

          isbns_by_book.each_slice(@batch_size) do |slice|
            results = @client.lookup(slice.flat_map(&:last).uniq)
            slice.each do |book_id, isbns|
              books_seen += 1
              records = isbns.flat_map { |isbn| results.fetch(isbn, []) }.uniq(&:oclc)
              next if records.empty?

              books_matched += 1
              records.each do |record|
                next if record.genre.blank?

                uses[record.genre] += 1
                books_by_term[record.genre] << book_id
              end
            end
          end

          terms = uses.sort_by { |term, n| [-n, term] }.to_h { |term, n| [term, {uses: n, books: books_by_term[term].size}] }
          head, tail = split(terms)
          write(HEAD_FILE, terms.slice(*head))
          write(TAIL_FILE, terms.slice(*tail))
          Result.new(success?: true, data: {books_seen:, books_matched:, terms:, head:, tail:}, errors: [])
        rescue ::Books::WorldCat::Exceptions::Error => e
          Result.new(success?: false, data: nil, errors: ["WorldCat lookup failed: #{e.message}"])
        end

        private

        # [[book_id, [isbn13, ...]], ...] in id order, E2E leftovers excluded.
        #
        # The WorldCat service rejects a whole batch if any ISBN fails its check digit, and
        # legacy identifier rows can carry invalid values (same reasoning as
        # Books::WorldCat::IsbnExport). So values Books::Isbn.normalize rejects are dropped and
        # the normalised isbn13 is what gets looked up, which is also what the client keys on.
        def isbns_by_book
          ::Identifier
            .where(identifiable_type: "Books::Book", identifier_type: :books_work_isbn13)
            .joins("INNER JOIN books_books ON books_books.id = identifiers.identifiable_id")
            .where.not("books_books.title ~ ?", ::Books::OpenLibrary::EvalExport::E2E_LEFTOVER_TITLE)
            .order(:identifiable_id)
            .pluck(:identifiable_id, :value)
            .group_by(&:first)
            .filter_map do |book_id, pairs|
              isbn13s = pairs.filter_map { |_, value| ::Books::Isbn.normalize(value)&.isbn13 }.uniq
              [book_id, isbn13s] if isbn13s.any?
            end
        end

        def split(terms)
          total = terms.values.sum { |v| v[:uses] }
          cumulative = 0
          head = []
          terms.each do |term, v|
            break if total.positive? && cumulative >= @head_share * total

            head << term
            cumulative += v[:uses]
          end
          [head, terms.keys - head]
        end

        def write(name, terms)
          @out_dir.mkpath
          CSV.open(@out_dir.join(name), "w") do |csv|
            csv << %w[term uses books]
            terms.each { |term, v| csv << [term, v[:uses], v[:books]] }
          end
        end
      end
    end
  end
end
