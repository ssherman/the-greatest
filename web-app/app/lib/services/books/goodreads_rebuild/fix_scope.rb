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
      #   :none        the export's title says what ours already says, or ours is the more complete
      #   :title_only  the authors agree and ours is a prefix of the export's (it lacks the subtitle):
      #                only the title and subtitle are rewritten
      #   :full        anything else, including every author difference and every book without a survey
      module FixScope
        module_function

        def call(book:, survey:, payload:)
          return :full unless survey&.authors_agree == true && !survey.wrong_book

          export = key(ExportFacts.clean_title(payload["full_title"]))
          ours = [book.title, ("#{book.title}: #{book.subtitle}" if book.subtitle.present?)].filter_map { |text| key(text) }
          return :full if export.nil? || ours.empty?

          return :none if ours.include?(export) || ours.any? { |ours_key| prefix?(ours_key, export) }
          return :title_only if ours.any? { |ours_key| prefix?(export, ours_key) }

          :full
        end

        # Whole-word prefix: "destination" opens "destination void", "art" does not open "artificial intelligence".
        def prefix?(longer, shorter)
          longer.start_with?("#{shorter} ")
        end

        def key(text) = ::Services::Books::Verification::Check.title_key(text)
      end
    end
  end
end
