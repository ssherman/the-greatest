# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Books
        # The books side of the list wizard core (books list wizard spec §1):
        # parser, finder query, finder, importer, search and display.
        class Adapter
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)
          LISTABLE_TYPE = "Books::Book"

          def listable_type = LISTABLE_TYPE

          def listable_includes = [:authors]

          def parse(list, content: nil)
            result = ::Services::Ai::Tasks::Lists::Books::RawParserTask.new(parent: list, content: content).call
            return Result.new(success?: false, data: [], errors: [result.error.presence || "Parsing failed"]) unless result.success?

            books = Array(result.data[:books] || result.data["books"])
            rows = books.map do |book|
              book = book.to_h.transform_keys(&:to_sym)
              {
                "rank" => book[:rank],
                "title" => book[:title].to_s.strip,
                "subtitle" => book[:subtitle].to_s.strip.presence,
                "authors" => Array(book[:authors]).map { |name| name.to_s.strip }.compact_blank,
                "year" => book[:publication_year]
              }
            end
            Result.new(success?: true, data: rows.reject { |row| row["title"].empty? }, errors: [])
          end

          def signature(title, authors)
            ::Services::Lists::Wizard::Core::Signature.call(title, authors)
          end

          def row_signature(item)
            metadata = item.metadata || {}
            book = item.listable
            title = metadata["title"].presence || book&.title
            authors = Array(metadata["authors"]).presence || Array(book&.authors&.map(&:name))
            signature(title, authors)
          end

          def query_for(item)
            metadata = item.metadata || {}
            ::DataImporters::Books::Book::ImportQuery.new(
              title: metadata["title"], subtitle: metadata["subtitle"],
              author_names: Array(metadata["authors"]), year: year_of(metadata)
            )
          end

          def finder
            ::DataImporters::Books::Book::Finder.new
          end

          # The Open Library keys a later Import re-check needs (spec §3): the
          # chosen work, the accepted key, its duplicates and both redirect-
          # source lists.
          def recheck_keys(match)
            keys = []
            external = match.external
            keys << external.external_key if external&.external_source == :open_library
            resolution = match.external_resolution
            if resolution
              keys << resolution.decision.key if resolution.accept?
              keys.concat(Array(resolution.decision.duplicates), Array(resolution.decision.duplicate_redirect_sources))
              keys.concat(Array(resolution.accepted&.redirect_sources))
            end
            keys.compact_blank.uniq
          end

          def find_record(id)
            ::Books::Book.find_by(id: id)
          end

          def row_display(item)
            metadata = item.metadata || {}
            {
              title: metadata["title"].presence || item.listable&.title,
              subtitle: metadata["subtitle"],
              authors: Array(metadata["authors"]).presence || Array(item.listable&.authors&.map(&:name)),
              year: metadata["year"]
            }
          end

          def record_display(book)
            {title: book.title, authors: book.authors.map(&:name), year: book.first_published_year}
          end

          private

          def year_of(metadata)
            ::Services::Lists::Wizard::Core::Signature.year(metadata["year"])
          end
        end
      end
    end
  end
end
