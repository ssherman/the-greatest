# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Whether an author is a real person. "Unknown", "Anonymous" and "Various"
      # are placeholders; "China" (the I Ching) is a place. Neither has a
      # nationality of its own to research. The decision uses the name only:
      # birth years on these records are junk.
      module AuthorKind
        VARIOUS_NAMES = ["various", "various authors"].freeze

        module_function

        def kind(author)
          return :placeholder if placeholder?(author.name)

          place_country(author) ? :place : :person
        end

        # The nationality row for an author whose whole name is a country.
        def place_country(author)
          return nil if placeholder?(author.name)

          country = ISO3166::Country.find_country_by_any_name(author.name.to_s.squish)
          nationality = country&.nationality.to_s.split(",").first.to_s.strip
          return nil if nationality.blank?

          CountryLookup.from_text([nationality]).countries.first
        end

        def placeholder?(name)
          UnknownAuthor.placeholder?(name) || VARIOUS_NAMES.include?(UnknownAuthor.normalize(name))
        end
      end
    end
  end
end
