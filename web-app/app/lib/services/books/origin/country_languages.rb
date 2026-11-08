# frozen_string_literal: true

module Services
  module Books
    module Origin
      # Which languages a book from a Books::Country is written in. Backs the
      # Wikidata shortcut: a country whose language matches the book's original
      # language needs no AI call. Everything compares lowercase.
      module CountryLanguages
        PATH = Rails.root.join("config/books/country_languages.yml")

        module_function

        def include?(country_name, language_name)
          return false if country_name.blank? || language_name.blank?

          table.fetch(country_name.to_s.downcase, []).include?(language_name.to_s.downcase)
        end

        def table
          @table ||= YAML.safe_load_file(PATH).to_h { |country, langs| [country.downcase, langs.map(&:downcase)] }.freeze
        end
      end
    end
  end
end
