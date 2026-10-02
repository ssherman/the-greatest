# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # The book's author step when Open Library gave it no authors: each of
        # the query's author names goes through the author importer by name,
        # linked in the query's order. Runs after Providers::OpenLibrary, so
        # it also covers an abstain, a reject and an unreachable service (the
        # service is not deployed to production). A book that already has
        # authors -- from Open Library just now, or from before -- is left
        # alone, the same ruling as the merger. Authors are imported without
        # their async enrichment; one this import created is remembered in
        # new_author_ids.
        class Authors < DataImporters::ProviderBase
          def initialize(new_author_ids: [])
            @new_author_ids = new_author_ids
          end

          def populate(book, query:, match: nil)
            return success_result(data_populated: []) if book.book_authors.any?
            return failure_result(errors: ["Book title required to link authors"]) if book.title.blank?

            names = Array(query&.author_names).map(&:to_s).compact_blank
            return failure_result(errors: ["No author names to import"]) if names.empty?

            linked = 0
            names.each_with_index do |name, index|
              imported = ::DataImporters::Books::Author::Importer.call(
                name: name, work_titles: [book.title].compact_blank,
                providers: ::DataImporters::Books::Author::Importer::BOOK_STEP_PROVIDERS
              )
              author = imported.item
              next unless author&.persisted?

              @new_author_ids << author.id if imported.created?
              link(book, author, index + 1)
              linked += 1
            end

            return failure_result(errors: ["No author could be imported"]) if linked.zero?

            book.authors.reset
            success_result(data_populated: [:authors])
          rescue => e
            failure_result(errors: ["Author step error: #{e.message}"])
          end

          private

          # Two names can resolve to one author ("Leo Tolstoy", "Lev Tolstoy");
          # book_authors is unique per (book, author).
          def link(book, author, position)
            return if book.book_authors.any? { |existing| existing.author_id == author.id }

            book.book_authors.build(author: author, position: position)
          end
        end
      end
    end
  end
end
