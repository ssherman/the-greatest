# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Does external evidence (not the AI's say-so) back a category? Answers per
      # category with the names of the sources that do: wikidata, wikipedia,
      # worldcat and goodreads. A category's names are its own name and
      # alternative names plus those of every row merged into it, because older
      # merges did not always copy them onto the target. Read-only.
      class Support
        WIKIDATA_LISTS = %w[genres main_subjects narrative_locations forms].freeze
        WIKIPEDIA_KEYS = %w[infobox_genre infobox_subject infobox_set_in].freeze

        def initialize(dossier)
          @dossier = dossier
        end

        def sources_for(category)
          names = names_for(category)
          sources = []
          sources << "wikidata" if wikidata_strings.any? { |text| text_match?(names, text) }
          sources << "wikipedia" if wikipedia_strings.any? { |text| text_match?(names, text) }
          sources << "worldcat" if worldcat_support?(category, names)
          sources << "goodreads" if goodreads_support?(category)
          sources
        end

        def supported?(category)
          sources_for(category).any?
        end

        # The sources_for names plus the looser evidence that admits a medium pick for ADDING only:
        # "held" (the book already has the category, any source), "text" (a name appears in the
        # description, Wikipedia lead or plot, or WorldCat summary) and "shelf" (a name appears in a
        # Goodreads shelf name the GenreMatcher missed). Never used to protect a legacy link from removal.
        def addition_sources(category, held:)
          sources = sources_for(category)
          names = names_for(category)
          sources << "held" if held
          sources << "text" if prose_strings.any? { |text| text_match?(names, text) }
          sources << "shelf" if shelf_names.any? { |shelf| text_match?(names, shelf) }
          sources
        end

        def supports_addition?(category, held:)
          addition_sources(category, held: held).any?
        end

        private

        attr_reader :dossier

        def names_for(category)
          (@names ||= {})[category.id] ||= begin
            merged = merged_rows[category.id] || []
            ([category.name] + Array(category.alternative_names) + merged.flat_map { |name, alts| [name] + Array(alts) })
              .map { |name| name.to_s.strip }.reject(&:empty?).uniq
          end
        end

        # One query per instance: [name, alternative_names] grouped by merge target.
        def merged_rows
          @merged_rows ||= ::Books::Category.where.not(merged_into_id: nil)
            .pluck(:merged_into_id, :name, :alternative_names)
            .group_by(&:first)
            .transform_values { |rows| rows.map { |_, name, alts| [name, alts] } }
        end

        def text_match?(names, text)
          return false if text.blank?

          text_key = Services::CategoryCleanup::NameNormalizer.twin_key(text)
          names.any? do |name|
            text.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i) ||
              (text_key && text_key == Services::CategoryCleanup::NameNormalizer.twin_key(name))
          end
        end

        def prose_strings
          @prose_strings ||= begin
            record = dossier.record.is_a?(Hash) ? dossier.record : {}
            wikipedia = dossier.wikipedia.is_a?(Hash) ? dossier.wikipedia : {}
            worldcat = dossier.worldcat.is_a?(Hash) ? dossier.worldcat : {}
            [record["description"], wikipedia["lead"], wikipedia["plot"], worldcat["summary"]].map(&:to_s).reject(&:blank?)
          end
        end

        def shelf_names
          @shelf_names ||= dossier.goodreads.is_a?(Hash) ? Array(dossier.goodreads["genres"]).map(&:to_s) : []
        end

        def wikidata_strings
          @wikidata_strings ||= begin
            section = dossier.wikidata
            section.is_a?(Hash) ? WIKIDATA_LISTS.flat_map { |key| Array(section[key]) }.map(&:to_s) : []
          end
        end

        def wikipedia_strings
          @wikipedia_strings ||= begin
            section = dossier.wikipedia
            section.is_a?(Hash) ? WIKIPEDIA_KEYS.flat_map { |key| Array(section[key]) }.map(&:to_s) : []
          end
        end

        def worldcat_support?(category, names)
          section = dossier.worldcat
          return false unless section.is_a?(Hash)

          case category.category_type
          when "genre", "audience"
            mapped = section["mapped_genres"].is_a?(Hash) ? section["mapped_genres"] : {}
            names.any? { |name| mapped.key?("#{category.category_type}:#{name}") }
          when "subject", "location"
            Array(section["subjects"]).any? { |heading| text_match?(names, heading.to_s) }
          else
            false
          end
        end

        def goodreads_support?(category)
          shelves = dossier.goodreads.is_a?(Hash) ? Array(dossier.goodreads["genres"]) : []
          shelves.any? do |shelf|
            found = matcher.match(shelf)
            found && (found.id == category.id || found.canonical&.id == category.id)
          end
        end

        def matcher
          @matcher ||= GoodreadsEnrichment::GenreMatcher.new
        end
      end
    end
  end
end
