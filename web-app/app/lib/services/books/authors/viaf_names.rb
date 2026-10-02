# frozen_string_literal: true

module Services
  module Books
    module Authors
      # VIAF name forms (spec §8). Library headings come inverted ("Tolstoy,
      # Leo, graf"), sometimes without the comma ("Willingham Stacy"), with
      # fuller forms in parentheses ("Tolkien, J. R. R. (John Ronald
      # Reuel)"); AutoSuggest rows add dates and descriptions ("Stacy
      # Willingham, 1991-"). Names are compared as sorted word sets, so word
      # order, punctuation and dates never decide a comparison.
      module ViafNames
        PARENTHESISED = /\([^)]*\)/

        module_function

        # Letters-only words, case and diacritics folded, in order.
        def words(text)
          normalized = ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).to_s
          normalized.gsub(PARENTHESISED, " ").unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.scan(/\p{L}+/)
        end

        def tokens(text) = words(text).sort

        def same?(left, right)
          ours = tokens(left)
          ours.any? && ours == tokens(right)
        end

        # The same words as `of`, in another order: "Yan Mo" of "Mo Yan".
        def reordering?(name, of:)
          words(name) != words(of) && tokens(name) == tokens(of)
        end

        # "Tolstoy, Leo, graf" is "Leo Tolstoy". Titles and anything after the
        # second comma are dropped, as are parenthesised fuller forms and
        # dates. Without a comma the order is unknowable: nil.
        #
        # This only undoes an inversion, so it must only be called on a
        # heading entered under a surname (Viaf::Distiller's "surname_first"
        # is true). A heading entered under a forename, such as "Marcus
        # Aurelius, Emperor of Rome" or "Hildegard, of Bingen, Saint", is not
        # inverted — the comma there introduces an epithet or title, not a
        # surname — and has no inversion to undo. Callers must not pass one.
        def natural(heading)
          text = heading.to_s.gsub(PARENTHESISED, " ").gsub(/\d[\d\s\-–?.]*/, " ")
          surname, forenames = text.split(",").map(&:squish)
          return nil if surname.blank? || forenames.blank?

          # A peerage heading repeats the surname at the end of the forenames
          # ("Byron, George Gordon Byron, Baron"): appending it again would
          # give "George Gordon Byron Byron", so the forenames alone are the
          # natural form. Only a forename part that ENDS with the surname's
          # (folded) words, and has more besides, counts: a forename that is
          # the same word as the surname is a real name ("Ford, Ford Madox"
          # is Ford Madox Ford, "Jerome, Jerome K." is Jerome K. Jerome).
          given = words(forenames)
          family = words(surname)
          return forenames if given.size > family.size && given.last(family.size) == family

          "#{forenames} #{surname}"
        end

        def latin?(text)
          letters = text.to_s.scan(/\p{L}/)
          letters.any? && letters.all? { |letter| letter.match?(/\p{Latin}/) }
        end
      end
    end
  end
end
