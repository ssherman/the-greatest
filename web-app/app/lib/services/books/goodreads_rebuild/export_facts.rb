# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # What the Goodreads export says about a book's main work (rebuild spec
      # §4): the biggest group of editions from its RebuildBookSurvey, boiled
      # down to the title, authors, identifiers and Open Library hints the book
      # finder needs. The title comes from the group's most-rowed edition, since
      # that is the one the user's export names most often. #to_payload is what
      # a repair verdict stores; .query_attributes turns a stored payload back
      # into ImportQuery arguments, so there is a single mapping either way.
      class ExportFacts
        Facts = Struct.new(:title, :subtitle, :full_title, :author_names, :year, :volume, :series_name, :isbn13, :isbn10,
          :goodreads_ids, :ol_work_keys, :edition_ids, :world_cat_agrees, keyword_init: true) do
          def to_payload = to_h.transform_keys(&:to_s)

          def to_query = ::DataImporters::Books::Book::ImportQuery.new(**ExportFacts.query_attributes(to_payload))
        end

        # A final parenthetical holding "#<number>", e.g. " (Crosstime (aka) Blake Walker #1)".
        SERIES_SUFFIX = /\s*\((?:[^()]|\([^()]*\))*\#\d+(?:[^()]|\([^()]*\))*\)\s*\z/

        # A trailing parenthetical (one level of nesting allowed).
        TRAILING_PARENTHETICAL = /\s*\((?:[^()]|\([^()]*\))*\)\s*\z/

        # A trailing parenthetical that says which book this is stays: an adaptation or guide
        # ("(Manga Classics)", "(SparkNotes Literature Guide)") or a volume or set ("(Volume 1)",
        # "(Box Set)"). Dropping it would turn a different book into the original.
        def self.informative?(parenthetical)
          ::DataImporters::Books::Book::DerivativeWork.marker?(parenthetical) ||
            parenthetical.match?(DecideFix::VOLUME_SHAPE) ||
            parenthetical.match?(::Services::Books::Verification::EditionCheck::SET_WORDS)
        end

        def self.call(survey:) = new(survey).call

        # On Goodreads a parenthetical at the END of a title is series, publisher-series or edition
        # information ("(Little Golden Book)", "(Spanish Edition)", "(Saddlewire) (Books of American
        # Wisdom)"), so every trailing one goes. One in the middle is part of the title ("How to Work with
        # (Almost) Anyone"). A title that is nothing but a parenthetical is returned as it was.
        def self.clean_title(text)
          return text if text.nil?

          cleaned = text.to_s
          while (trailing = cleaned[TRAILING_PARENTHETICAL])
            break if informative?(trailing) && !trailing.match?(SERIES_SUFFIX)

            cleaned = cleaned.delete_suffix(trailing)
          end
          cleaned = cleaned.strip
          cleaned.empty? ? text : cleaned
        end

        # Payload hash (string keys, as it comes back from jsonb) to ImportQuery keyword arguments.
        def self.query_attributes(payload)
          {
            title: payload["title"],
            subtitle: payload["subtitle"],
            author_names: payload["author_names"] || [],
            year: payload["year"],
            isbn13: payload["isbn13"] || [],
            isbn10: payload["isbn10"] || [],
            goodreads_id: payload["goodreads_ids"] || [],
            open_library_work_key: Array(payload["ol_work_keys"]).first,
            series_name: payload["series_name"],
            series_number: payload["volume"]
          }
        end

        def initialize(survey)
          @group = survey.groups.first
        end

        def call
          ids = @group["edition_ids"]
          editions = ::Books::GoodreadsEdition.where(id: ids).to_a
          rows = ::Books::GoodreadsImportRow.where(goodreads_edition_id: ids).group(:goodreads_edition_id).count
          by_rows = editions.sort_by { |e| [-rows.fetch(e.id, 0), e.goodreads_book_id.to_i] }
          found = ::Books::RebuildEditionEvidence.for_editions(editions)
          evidence = by_rows.filter_map { |e| found[e.id] }
          main = by_rows.first

          full_title = self.class.clean_title(main.title.to_s.sub(SERIES_SUFFIX, "").strip)
          title, subtitle = split_title(full_title)
          Facts.new(
            title: title, subtitle: subtitle, full_title: full_title,
            author_names: authors(by_rows, rows),
            year: @group["year"], volume: @group["volume"], series_name: main.series_name.presence,
            isbn13: by_rows.filter_map { |e| e.isbn13.presence }.uniq, isbn10: by_rows.filter_map { |e| e.isbn10.presence }.uniq,
            goodreads_ids: by_rows.map { |e| e.goodreads_book_id.to_s }.uniq,
            ol_work_keys: evidence.flat_map { |e| Array(e.ol_work_keys).uniq }.tally.sort_by.with_index { |(_, n), i| [-n, i] }.map(&:first),
            edition_ids: ids, world_cat_agrees: evidence.any?(&:agrees?)
          )
        end

        private

        def split_title(full_title)
          head, tail = full_title.split(":", 2).map(&:strip)
          (head.present? && tail.present?) ? [head, tail] : [full_title, nil]
        end

        def authors(by_rows, rows)
          by_rows.group_by(&:primary_author).reject { |name, _| name.blank? }
            .sort_by.with_index { |(_, es), i| [-es.sum { |e| rows.fetch(e.id, 0) }, i] }.map(&:first)
        end
      end
    end
  end
end
