# frozen_string_literal: true

module Services
  module Books
    module Origin
      # The deterministic path that skips the AI call: Wikidata names exactly
      # one country of origin, one of the book's authors is from that country,
      # and the book's original language is spoken there. Anything short of
      # all three returns nil and the caller asks the model.
      module Shortcut
        module_function

        def call(dossier)
          wikidata = dossier.wikidata
          return nil if wikidata.blank?
          return nil unless single_country?(wikidata)

          matches = Array(wikidata["country_matches"])
          return nil unless matches.size == 1

          name = matches.first
          return nil unless dossier.author_countries.include?(name)
          return nil unless CountryLanguages.include?(name, language(dossier))

          CountryLookup.from_text([name]).countries.first
        rescue NoMethodError, TypeError
          nil
        end

        # A schema-1 evidence row has no country_ids; it keeps countries only.
        def single_country?(wikidata)
          ids = Array(wikidata["country_ids"])
          ids.any? ? ids.size == 1 : Array(wikidata["countries"]).size == 1
        end

        def language(dossier)
          languages = Array(dossier.wikidata["languages"])
          [
            dossier.record["original_language"],
            (languages.first if languages.size == 1),
            dossier.book_facts&.dig("original_language")
          ].find(&:present?)
        end

        private_class_method :single_country?, :language
      end
    end
  end
end
