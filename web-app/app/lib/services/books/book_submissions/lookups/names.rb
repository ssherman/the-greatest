# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # Text cleaning shared by the sources.
        module Names
          module_function

          # Jr/Sr/II/III/IV and company suffixes: they follow the name whichever
          # way round the heading is written.
          SUFFIXES = /\A(?:Jr|Sr|II|III|IV|Inc|Ltd|LLC|Co|Corp)\.?\z/i
          # A trailing period stays on an initial or abbreviation ("K.", "Jr.",
          # "Дж." in "Сара Дж."): a single letter, a known abbreviation, or a
          # word of up to three letters after another word. A heading's own
          # closing period ("Zadie.", "Ти.") goes.
          ABBREVIATIONS = /\A(?:Jr|Sr|St|Dr)\z/i

          # What a person did on the book, written after the name in a heading.
          ROLES = /\A(?:(?:joint|cover|co-?)\s*)?(?:author|artist|illustrator|editor|translator|compiler|writer|photographer|narrator|composer|creator|contributor|adapter|reader|ed|tr|trans|ill)s?(?:\s+of\b.*)?\.?\z/i
          # What is left of a date once DATES has taken the numbers.
          DATE_WORDS = /\A(?:approximately|active|born|died|flourished|fl|ca|circa|b|d)\.?\z/i
          # Rank or sanctity that follows a name, and is dropped. After a saint
          # or a ruler the heading is "Thomas, Aquinas, Saint": the name before
          # it is already in given-name-first order and is not flipped. After
          # nobility it is "Tolstoy, Leo, graf": surname first, flipped as usual.
          DIRECT_EPITHETS = /\A(?:saint|st|emperor|empress|king|queen|pope|prince|princess|bishop)\b/i
          EPITHETS = /#{DIRECT_EPITHETS.source}|\A(?:sir|duke|duchess|baron|count|graf|lord|lady|dame)\b/i
          # PARENTHESES and DATES are applied first; this is a slash that stands
          # alone ("Title / creator"), not one inside "Either/Or" or "9/11".
          SLASH_STATEMENT = %r{\s+/(?=\s|\z).*}m

          def text(value)
            value.to_s.squish.first(::Books::BookSubmission::MAX_LENGTH).presence
          end

          # Integers (including years before 1000 and BC ones, negative) pass
          # through; only strings are parsed.
          def year(value)
            return value if value.is_a?(Integer)

            value.to_s[/\A\s*(\d{4})/, 1]&.to_i
          end

          # A WorldCat creator. Most are already in direct order and come out
          # unchanged; "Last, First" is flipped only when the second part looks
          # like a given name. The first part is kept whatever it holds ("50
          # Cent", "Jennifer 8. Lee"); later parts that hold a digit are dates
          # ("approximately 1340-1400", "active 8th century B.C.") and go, as do
          # role words ("author"). Epithets are dropped; after a saint or a ruler
          # ("Thomas, Aquinas, Saint") the name is already in direct order. A second part
          # that is not a given name ("Leonardo, da Vinci") is joined as
          # written: "Leonardo da Vinci".
          def world_cat_person(raw)
            name = raw.to_s.gsub(::Services::Books::Verification::WorldCatCheck::PARENTHESES, "")
              .sub(::Services::Books::Verification::WorldCatCheck::DATES, "")
            first, *rest = name.split(",").map { |part| tidy(part) }
            return nil if first.nil?

            rest = rest.compact.reject { |part| part.match?(/\d/) || part.match?(ROLES) || part.match?(DATE_WORDS) }
            suffixes, rest = rest.partition { |part| part.match?(SUFFIXES) }
            epithets, rest = rest.partition { |part| part.match?(EPITHETS) }
            direct = epithets.any? { |part| part.match?(DIRECT_EPITHETS) }
            given = rest.first
            ordered = if given && !direct && given_name?(given)
              [given, first]
            else
              [first, *rest]
            end
            tidy((ordered + suffixes).join(" "))
          end

          def given_name?(part)
            part.match?(/\A[[:alpha:]]/) && !part.match?(/\A\p{Ll}/) && !part.split.first.match?(SUFFIXES)
          end

          # "Title / creator" loses everything after the slash and "Title : subtitle"
          # splits. A subtitle the record carries wins over the split one.
          def world_cat_title(title, subtitle)
            main, _, rest = title.to_s.sub(SLASH_STATEMENT, "").partition(" : ")
            [tidy(main), tidy((subtitle.presence || rest).to_s.sub(SLASH_STATEMENT, ""))]
          end

          def tidy(value)
            cleaned = value.to_s.squish.sub(%r{\s*[,;:/]+\z}, "")
            cleaned = cleaned.chomp(".") unless keeps_period?(cleaned)
            cleaned.strip.presence
          end

          def keeps_period?(text)
            return false unless text.end_with?(".")

            word = text.split.last.chomp(".")
            word.length == 1 || word.match?(ABBREVIATIONS) || (text.include?(" ") && word.length <= 3)
          end
        end
      end
    end
  end
end
