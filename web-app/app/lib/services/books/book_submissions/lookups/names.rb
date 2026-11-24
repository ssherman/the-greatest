# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # Text cleaning shared by the sources.
        module Names
          module_function

          SUFFIXES = /\A(?:Jr|Sr|II|III|IV)\.?\z/i
          # A trailing period stays on an initial or an abbreviation ("K.", "Jr.").
          ABBREVIATION = /(?:\A|\s)(?:[[:alpha:]]|Jr|Sr|St|Dr)\.\z/

          def text(value)
            value.to_s.squish.first(::Books::BookSubmission::MAX_LENGTH).presence
          end

          def year(value)
            value.to_s[/\A\s*(\d{4})/, 1]&.to_i
          end

          # A WorldCat creator: "King, Martin Luther, Jr., 1929-1968." becomes
          # "Martin Luther King Jr.". Dates are the only comma parts that hold a
          # digit, so any such part goes ("approximately 1340-1400", "active
          # 8th century B.C."). Other extra parts ("graf", "Saint") are
          # epithets we cannot place, so they are dropped rather than misplaced.
          def world_cat_person(raw)
            name = raw.to_s.gsub(::Services::Books::Verification::WorldCatCheck::PARENTHESES, "")
              .sub(::Services::Books::Verification::WorldCatCheck::DATES, "")
            parts = name.split(",").map(&:squish).reject { |part| part.empty? || part.match?(/\d/) }
            return nil if parts.empty?

            last, first, *rest = parts
            suffix = rest.find { |part| part.match?(SUFFIXES) }
            tidy([first, last, suffix].compact.join(" "))
          end

          # "Title / creator" loses everything after the slash and "Title : subtitle"
          # splits. A subtitle the record carries wins over the split one.
          def world_cat_title(title, subtitle)
            main, _, rest = title.to_s.sub(%r{\s*/.*\z}m, "").partition(" : ")
            [tidy(main), tidy(subtitle.presence || rest)]
          end

          def tidy(value)
            cleaned = value.to_s.squish.sub(%r{\s*[,;:/]+\z}, "")
            cleaned = cleaned.chomp(".") unless cleaned.match?(ABBREVIATION)
            cleaned.strip.presence
          end
        end
      end
    end
  end
end
