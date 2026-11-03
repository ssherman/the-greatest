# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # The match facts for one Goodreads edition (re-import spec). The legacy
      # import cut titles at the colon and kept one author, so the facts are
      # built from the CSV rows' FULL title and every credited author instead.
      class EditionFacts
        Facts = Struct.new(:full_title, :title, :subtitle, :author_names, :year, :isbn13, :isbn10, :goodreads_book_id,
          :series_name, :series_number, keyword_init: true) do
          def to_h = super.stringify_keys

          # additional authors are left out on purpose: Goodreads mixes co-authors with translators and
          # illustrators, so only the primary author is a creator for matching.
          def to_query
            ::DataImporters::Books::Book::ImportQuery.new(
              title: title, subtitle: subtitle, author_names: author_names, year: year,
              isbn13: [isbn13], isbn10: [isbn10], goodreads_id: [goodreads_book_id.to_s],
              series_name: series_name, series_number: series_number
            )
          end
        end

        def self.call(edition:) = new(edition).call

        def initialize(edition)
          @edition = edition
        end

        def call
          full_title = most_common_row_title || @edition.title.to_s
          title, subtitle = split(GoodreadsRebuild::ExportFacts.clean_title(full_title))
          Facts.new(
            full_title: full_title, title: title, subtitle: subtitle, author_names: author_names,
            year: @edition.original_publication_year || @edition.year_published,
            isbn13: @edition.isbn13.presence, isbn10: @edition.isbn10.presence, goodreads_book_id: @edition.goodreads_book_id,
            series_name: @edition.series_name.presence, series_number: @edition.series_number.presence
          )
        end

        private

        # Ties go to the lowest row id: group_by keeps first-seen order over rows sorted by id.
        def most_common_row_title
          titles = ::Books::GoodreadsImportRow.where(goodreads_edition_id: @edition.id).order(:id)
            .pluck(Arel.sql("raw ->> 'Title'")).map(&:presence).compact
          titles.group_by(&:itself).max_by { |_, group| group.size }&.first
        end

        def author_names
          [@edition.primary_author, *@edition.additional_authors]
            .map { |name| Services::Text::NameNormalizer.call(name.to_s).presence }.compact.uniq
        end

        def split(text)
          head, tail = text.split(": ", 2).map(&:strip)
          (head.present? && tail.present?) ? [head, tail] : [text, nil]
        end
      end
    end
  end
end
