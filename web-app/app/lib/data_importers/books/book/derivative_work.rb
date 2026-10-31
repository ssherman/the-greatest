# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # Whether two titles name a work and something made FROM it. A graphic
      # novel, a manga, a pop-up book, a stage or screen adaptation, a retelling,
      # a study guide, a summary or a commentary shares nearly every word with the
      # classic it is based on, so title matching, search and the AI all pull it
      # to the original: the Goodreads rebuild proposed 28 wrong merges of this
      # kind (Watership Down: The Graphic Novel into Watership Down). A
      # deterministic rule is the only thing that holds across every mode.
      #
      # The test is symmetric and only about markers: when one side carries a
      # marker the other lacks, the two are different books. Two titles that both
      # say "Graphic Novel" are not told apart here. "Annotated", "illustrated",
      # "edition", "translation" and "critical edition" are deliberately NOT
      # markers: those are the same work in another form.
      module DerivativeWork
        MARKERS = [
          "graphic novel", "manga", "pop up", "stage adaptation", "the play", "screenplay",
          "retelling", "retold", "revisited", "adapted", "adaptation",
          "study guide", "literature guide", "reading guide", "guide to reading",
          "summary", "analysis", "sparknotes", "cliffsnotes", "commentary", "companion", "workbook",
          # German, Spanish and French forms that are not already the English words.
          "novela grafica", "roman graphique", "bande dessinee", "adaptacion"
        ].freeze

        PATTERNS = MARKERS.to_h { |marker| [marker, /(?<![[:alnum:]])#{Regexp.escape(marker)}(?![[:alnum:]])/] }.freeze

        module_function

        # True when exactly one side carries a marker the other does not.
        def differ?(title_a, title_b)
          markers(title_a) != markers(title_b)
        end

        def markers(text)
          normalized = normalize(text)
          return [] if normalized.empty?

          PATTERNS.select { |_marker, pattern| normalized.match?(pattern) }.keys.sort
        end

        # Lowercase, accents removed, every run of punctuation (hyphens included)
        # one space, so "Pop-Up", "pop up" and "Bande Dessinée" meet the list.
        def normalize(text)
          text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(/[^[:alnum:]]+/, " ").strip
        end
      end
    end
  end
end
