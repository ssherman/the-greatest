# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # How much a fix_identity verdict has to change its book. A full reset
      # wipes the book's description, categories, covers, editions, links,
      # identifiers and authors and rebuilds them through enrichment, which is
      # only worth it when the book is really the wrong one. Measured on
      # production, most recorded fixes differ from the book only in Goodreads'
      # series noise ("Euthydemus" / "Euthydemus (Hackett Classics)") or in a
      # subtitle our title lacks.
      #
      #   :none        the export's title equals our title, or our "title: subtitle"
      #   :title_only  the export's title is ours and it has a subtitle ours lacks: only the title and
      #                subtitle are rewritten
      #   :full        anything else, including any difference in the set of authors and every book
      #                without a survey
      module FixScope
        module_function

        def call(book:, survey:, payload:)
          return :full unless survey&.authors_agree == true && !survey.wrong_book && same_authors?(book, payload)

          export = key(ExportFacts.clean_title(payload["full_title"]))
          ours = [book.title, ("#{book.title}: #{book.subtitle}" if book.subtitle.present?)].filter_map { |text| key(text) }
          return :full if export.nil? || ours.empty?

          return :none if ours.include?(export)
          return :title_only if stripped_subtitle?(book, payload)

          :full
        end

        # The survey's authors_agree means at least one author in common. A same-book verdict needs the same
        # set: every export name linked to one of our authors, and those authors exactly the book's.
        # A missing author_links never matches.
        def same_authors?(book, payload)
          names = Array(payload["author_names"])
          links = Hash(payload["author_links"])
          names.any? && names.all? { |name| links[name] } && names.filter_map { |name| links[name] }.uniq.sort == book.author_ids.sort
        end

        # The only difference is a subtitle our title lacks ("Destination" / "Destination: Void"): the export's
        # own title is ours and it has a subtitle. A title that merely extends or is extended by the other
        # ("Dune" / "Dune Messiah", "Silo 1" / "Silo") may be another book, so it gets the full reset.
        def stripped_subtitle?(book, payload)
          book.subtitle.blank? && payload["subtitle"].present? &&
            key(ExportFacts.clean_title(payload["title"])) == key(book.title)
        end

        def key(text) = ::Services::Books::Verification::Check.title_key(text)
      end
    end
  end
end
