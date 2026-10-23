# frozen_string_literal: true

module Services
  module Books
    module AlternateTitles
      # A prompt an admin pastes into a deep-research agent (too costly to run
      # per title through the API) to settle one alternate title the AI was
      # unsure of: is it this book under another name, or a different work?
      module ResearchPrompt
        module_function

        OTHER_TITLES_LIMIT = 30

        def call(row)
          book = row.titleable
          others = Array(book.alternate_titles).reject { |title| title == row.title }.first(OTHER_TITLES_LIMIT)

          <<~PROMPT
            I maintain a catalog of books and need to know whether an alternate title really belongs to this book.

            Title: #{[book.title, book.subtitle.presence].compact.join(": ")}
            Author(s): #{book.authors.map(&:name).join(", ").presence || "unknown"}
            First published: #{book.first_published_year || "unknown"}
            Original language: #{book.original_language&.name || "unknown"}
            Other titles we hold for this book: #{others.join("; ").presence || "none"}

            Alternate title in question: "#{row.title}"
            Our AI reviewer's view: #{ai_view(row)}

            Please research whether "#{row.title}" is a title under which this same work has been published: a translation, a regional or later edition title, a spelling variant, or a fuller or shorter form of the title. The other possibility is that it is a different work: another book, a single volume or part of this one, an edition that bundles it with other works, or not a real title at all.

            - If it is this work: give the language and, where you can find them, the publisher, country and year of an edition published under that title, with a source (a library catalog, WorldCat, Open Library, a national library, or the publisher).
            - If it is a different work: say what that work is (title, author, year) and how it relates to this book.
            - If you cannot find evidence either way, say so rather than guessing.

            End with one line: VERDICT: same work | different work | unsure
          PROMPT
        end

        def ai_view(row)
          return "not reviewed yet" if row.verdict.nil?

          confidence = row.confidence ? format("%.2f", row.confidence) : "unknown"
          "#{row.verdict.humanize(capitalize: false)} (#{row.category.to_s.humanize(capitalize: false)}, confidence #{confidence}): #{row.reason}"
        end
      end
    end
  end
end
