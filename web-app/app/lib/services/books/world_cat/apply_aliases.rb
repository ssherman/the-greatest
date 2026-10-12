# frozen_string_literal: true

module Services
  module Books
    module WorldCat
      # Adds every genre-verdict term as an alternative name on its genre category,
      # the same field Categories::Merger fills, so the mapping is visible in the
      # admin and survives future merges. Idempotent.
      class ApplyAliases
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(map:)
          new(map).call
        end

        def initialize(map)
          @map = map
        end

        def call
          return Result.new(success?: false, data: nil, errors: [Backfill::EMPTY_MAP]) if @map.size.zero?

          updated = 0
          added = 0
          missing = []
          @map.terms_by_genre.each do |genre_name, terms|
            category = ::Books::Category.active.genre.by_name(genre_name).first
            if category.nil?
              missing << genre_name
              next
            end
            aliases = terms.reject { |t| t == category.name || category.alternative_names.any? { |a| a.casecmp?(t) } }
            next if aliases.empty?

            category.update!(alternative_names: category.alternative_names + aliases)
            updated += 1
            added += aliases.size
          end
          Result.new(success?: true, data: {categories_updated: updated, aliases_added: added, missing_genres: missing}, errors: [])
        end
      end
    end
  end
end
