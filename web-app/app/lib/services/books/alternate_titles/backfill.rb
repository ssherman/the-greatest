# frozen_string_literal: true

module Services
  module Books
    module AlternateTitles
      # Copies a book's alternate_titles array into books_alternate_titles as
      # legacy/kept rows. Idempotent: a title already present (in any status,
      # including removed) is skipped, so a removed title is never revived.
      class Backfill
        def self.call(book)
          now = Time.current
          seen = {}
          rows = book.alternate_titles.filter_map do |title|
            normalized = ::Services::Books::Verification::Check.normalize(title)
            next if normalized.blank? || seen[normalized]
            seen[normalized] = true
            {book_id: book.id, title: title, normalized_title: normalized,
             source: ::Books::AlternateTitle.sources[:legacy],
             status: ::Books::AlternateTitle.statuses[:kept],
             created_at: now, updated_at: now}
          end
          return 0 if rows.empty?

          ::Books::AlternateTitle.insert_all(rows, unique_by: [:book_id, :normalized_title]).length
        end

        def self.all
          ::Books::Book.where("cardinality(alternate_titles) > 0").find_each.sum { |book| call(book) }
        end
      end
    end
  end
end
