# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # Text cleaning shared by the sources.
        #
        # A wrong author is worse than no answer: the submission falls through
        # to the next source for the cost of one lookup. So a WorldCat creator
        # is accepted only in a few shapes we can read with certainty, and is
        # nil in every other shape (see world_cat_person).
        module Names
          module_function

          PARENTHESES = ::Services::Books::Verification::WorldCatCheck::PARENTHESES
          DATES = ::Services::Books::Verification::WorldCatCheck::DATES
          SQUARE_BRACKETS = /\s*\[[^\]]*\]/
          # A comma part that is only life dates, once its closing period is gone.
          LIFE_DATES = /\A\d{3,4}\??\s*-\s*(?:\d{3,4}\??)?\z/
          ROLES = %w[author artist illustrator editor translator writer creator narrator compiler].freeze
          SUFFIX = /\A(?:Jr|Sr|II|III|IV)\.?\z/i
          PARTICLES = %w[de da di do du des del della la le van von der den ten ter zu y e al el bin ibn].freeze
          # Titles, epithets, companies and connectives: a given-name part that
          # holds one as a whole word is not a given name.
          BLOCKED_WORDS = %w[saint st sir dame lord lady king queen emperor empress pope prince princess duke duchess
            count countess baron baroness earl marquis bishop archbishop cardinal rabbi of and inc ltd llc co company
            press publishing university ministry department &].freeze
          # Corporate and connective words: a surname part holding one is a body,
          # not a person ("University of California, Los Angeles"). Not the title
          # words: King, Pope and Bishop are real surnames.
          CORPORATE_WORDS = %w[of and & inc ltd llc co company press publishing university ministry department].freeze
          # Suffixes and credentials never belong inside a given-name part.
          POST_NAME_WORDS = %w[jr sr ii iii iv phd ph md mba cpa esq rn dds dvm jd msc bsc].freeze
          # Two or more people in one value.
          SEVERAL_PEOPLE = %r{[/;|&،]}
          # Native order there is surname first, so a "Last, First" flip would reverse it.
          SURNAME_FIRST_SCRIPTS = /[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/
          # Scripts with no case in ordinary use: a word cannot be "lowercase" there.
          UNCASED_SCRIPTS = %w[Han Hiragana Katakana Hangul Georgian Hebrew Arabic Thai Lao Devanagari Bengali Gurmukhi
            Gujarati Tamil Telugu Kannada Malayalam Sinhala Khmer Myanmar Tibetan Ethiopic Syriac Thaana Mongolian].freeze
          UNCASED_START = Regexp.new("\\A[#{UNCASED_SCRIPTS.map { |script| "\\p{#{script}}" }.join}]")
          INITIAL = /\A\p{L}\p{M}*\.\z/
          DOTTED_INITIALS = /\A(?:\p{L}\p{M}*\.-?){2,}\z/
          SUFFIX_ABBREVIATION = /\A(?:Jr|Sr)\.\z/i
          # A slash standing alone ("Title / creator"), not one inside "Either/Or" or "9/11".
          SLASH_STATEMENT = %r{\s+/(?=\s|\z).*}m

          def text(value)
            scrubbed(value).squish.first(::Books::BookSubmission::MAX_LENGTH).presence
          end

          # Outside text can be binary or hold a NUL; neither can be stored as JSON.
          def scrubbed(value)
            string = value.to_s
            string = string.dup.force_encoding(Encoding::UTF_8) unless string.encoding == Encoding::UTF_8
            string.scrub("").delete("\u0000")
          end

          # Integers (including years before 1000 and BC ones, negative) pass
          # through; only strings are parsed.
          def year(value)
            return value if value.is_a?(Integer)

            value.to_s[/\A\s*(\d{4})/, 1]&.to_i
          end

          # A WorldCat creator, or nil when it is not in a shape we are sure of.
          # A bracketed part, trailing life dates and a closing period go.
          # - No comma: the text as it is.
          # - "Last, First": the given-name part is accepted only when every
          #   word is capitalised or in a script without case, with lowercase
          #   particles ("van", "de") only trailing, and holds no title,
          #   epithet, company or connective word. Life dates and a closed list
          #   of role words may follow, and Jr/Sr/II/III/IV as a whole part.
          #   Output is "First Last" (or "First Last Jr.").
          # - Anything else with a comma (an epithet part, a part mixing words
          #   and dates, a lowercase given name) is nil.
          def world_cat_person(raw)
            raw = scrubbed(raw)
            return nil if raw.match?(SEVERAL_PEOPLE)

            # A period right after a removed bracket belonged to it ("Richard (Rick). Yancey").
            name = raw.gsub(/#{PARENTHESES}\.?/o, "").gsub(/#{SQUARE_BRACKETS}\.?/o, "").sub(DATES, "").squish
            return nil if name.empty?
            return strip_closing_period(name).presence unless name.include?(",")
            return nil if name.match?(SURNAME_FIRST_SCRIPTS)

            comma_person(name)
          end

          # "Title / creator" loses everything after the slash and "Title : subtitle"
          # splits. A subtitle the record carries wins over the split one.
          def world_cat_title(title, subtitle)
            subtitle = scrubbed(subtitle)
            main, _, rest = scrubbed(title).sub(SLASH_STATEMENT, "").partition(" : ")
            [tidy_title(main), tidy_title((subtitle.presence || rest).sub(SLASH_STATEMENT, ""))]
          end

          def tidy_title(value)
            cleaned = scrubbed(value).squish.sub(%r{\s*[,;:/]+\z}, "")
            closing_period_stays?(cleaned) ? cleaned.presence : cleaned.chomp(".").strip.presence
          end

          # A plain closing period goes ("The Civil War."). It stays when the
          # last word holds another period ("U.S.A.", "B.C."), is Inc, Ltd, Co,
          # Jr or Sr (an ellipsis is a word holding other periods).
          def closing_period_stays?(text)
            return true unless text.end_with?(".")

            word = text.split.last
            word.chomp(".").include?(".") || word.match?(/\A(?:Inc|Ltd|Co|Jr|Sr)\.\z/i)
          end

          # A closing period goes unless the last word is an initial ("K."),
          # dotted initials ("M.C.") or Jr./Sr.
          def strip_closing_period(text)
            return text unless text.end_with?(".")

            word = text.split.last
            return text if word.match?(INITIAL) || word.match?(DOTTED_INITIALS) || word.match?(SUFFIX_ABBREVIATION)

            text.chomp(".").rstrip
          end

          def comma_person(name)
            surname, *parts = name.split(",", -1).map { |part| tidy_part(part) }
            parts.pop while parts.last == ""
            return nil if surname.empty? || corporate?(surname)

            given = suffix = nil
            parts.each_with_index do |part, index|
              if part.match?(LIFE_DATES) || ROLES.include?(part)
                next
              elsif part.match?(SUFFIX) && suffix.nil? && (index.zero? || given)
                suffix = part
              elsif index.zero? && given_name?(part)
                given = part
              else
                return nil
              end
            end
            [given, surname, suffix].compact.join(" ")
          end

          # A period standing alone between words is dropped, then the closing period.
          def tidy_part(part)
            strip_closing_period(part.squish.gsub(/(?<=\S)\s+\.\s+(?=\S)/, " "))
          end

          def corporate?(text)
            text.split.any? { |word| CORPORATE_WORDS.include?(word.downcase.delete_suffix(".")) }
          end

          def given_name?(part)
            words = part.split
            return false if words.empty?
            return false if words.any? { |word| BLOCKED_WORDS.include?(word.downcase.delete_suffix(".")) }
            return false if words.any? { |word| POST_NAME_WORDS.include?(word.downcase.delete(".,")) }

            particles = false
            names = 0
            words.each do |word|
              if word.match?(/\A[\p{Lu}\p{Lt}]/) || word.match?(UNCASED_START)
                return false if particles

                names += 1
              elsif PARTICLES.include?(word)
                particles = true
              else
                return false
              end
            end
            names.positive?
          end
        end
      end
    end
  end
end
