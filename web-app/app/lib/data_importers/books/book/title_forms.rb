# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      # The forms one book title takes: whole ("Andrew Johnson: A Biography"),
      # split into our title and subtitle columns, and as Goodreads and Amazon
      # write it, with a closing note ("(Brides of Nap City Book 1)").
      #
      # The finder and the Goodreads import share this so they cannot drift: a
      # book created from a CSV title must be an exact match for that title the
      # next time it comes in, however it was stored.
      module TitleForms
        OPENING = "([{"
        CLOSING = ")]}"

        # A final parenthetical, one level of nesting allowed.
        TRAILING_NOTE = /\s*\((?<note>(?:[^()]|\([^()]*\))*)\)\s*\z/

        NUMBER_WORDS = %w[one two three four five six seven eight nine ten eleven twelve].join("|")
        VOLUME_WORDS = "books?|bk|vols?|volumes?|volumen|parts?|tome|tomo|tom|teil|band|buch|livre|libro|livro|parte|partie|deel"

        # "Series Book 1", "Series, Vol. 7", "Series, 3": a series name, then one
        # number. Three digits at most, so a year is never read as a number. A
        # bare "(Volume 2)" has no name: it says which volume this is, and stays.
        SERIES_NOTE = /\A(?<series>.*\p{L}.*?)(?:,?\s+(?:#{VOLUME_WORDS})\.?\s*\#?(?:\d{1,3}|#{NUMBER_WORDS})|,\s*\d{1,3})\z/i

        # "(Volume 2, Book 1)": the part before the last number is itself a volume.
        NUMBERED = /\b(?:#{VOLUME_WORDS})\.?\s*\#?(?:\d|(?:#{NUMBER_WORDS})\b)/i

        LANGUAGES = "english|spanish|french|german|italian|portuguese|dutch|swedish|danish|norwegian|finnish|polish|czech|" \
          "hungarian|romanian|greek|turkish|russian|ukrainian|arabic|hebrew|persian|hindi|chinese|japanese|korean|vietnamese|" \
          "indonesian|catalan"
        EDITION_NOTE = /\A(?:(?:#{LANGUAGES}|kindle|hardcover|paperback|ebook|audio) edition|mobi|epub|kindle|hardcover|paperback|ebook|audiobook|unabridged)\z/i

        module_function

        # Cut at the first colon that is outside brackets and has a space after
        # it. A colon inside brackets belongs to the bracket: cutting there gave
        # "Accounting 2 (Quick Study" / "Business)".
        def split(text)
          return [text, nil] if text.blank?

          depth = 0
          text.each_char.with_index do |char, index|
            if OPENING.include?(char)
              depth += 1
            elsif CLOSING.include?(char)
              depth -= 1 if depth.positive?
            elsif char == ":" && depth.zero? && text[index + 1]&.match?(/\s/)
              head = text[0...index].strip
              tail = text[(index + 1)..].strip
              return [head, tail] if head.present? && tail.present?
            end
          end
          [text, nil]
        end

        # Without closing notes that only say which series or format this is.
        # Any other bracket may tell one book from another ("(Volume 2)", "(Box
        # Set)", "(Graphic Novel)", "(Classics Illustrated)") and stays.
        def without_note(text)
          kept = text.to_s
          while (match = TRAILING_NOTE.match(kept))
            rest = match.pre_match.strip.sub(/\s*[:;,]\z/, "")
            break if rest.empty? || !droppable?(match[:note].strip, rest)

            kept = rest
          end
          text.nil? ? nil : kept
        end

        # What to search for when the whole title finds nothing: no closing
        # brackets at all and no subtitle. Only ever a way to find candidates,
        # never proof that two titles are the same.
        def main(text)
          kept = text.to_s
          while (match = TRAILING_NOTE.match(kept)) && match.pre_match.strip.present?
            kept = match.pre_match.strip
          end
          split(kept).first
        end

        def full(title, subtitle) = [title, subtitle].compact_blank.join(": ")

        def droppable?(note, rest)
          return true if note.match?(EDITION_NOTE)

          match = SERIES_NOTE.match(note)
          return false if match.nil? || note.match?(::Services::Books::Verification::EditionCheck::SET_WORDS) || DerivativeWork.marker?(note)

          return false if match[:series].match?(NUMBERED)

          series = DerivativeWork.normalize(match[:series])
          [rest, main(rest)].none? { |title| DerivativeWork.normalize(title) == series }
        end
        private_class_method :droppable?
      end
    end
  end
end
