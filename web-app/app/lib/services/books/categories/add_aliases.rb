# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Turns the report's alias suggestions into alternative names: for each
      # genre name the judge said means a listed genre or audience, adds the name
      # to that category's alternative_names. A name that already matches an
      # active genre or audience (name, alternative name or twin key, through the
      # GenreMatcher) is skipped and reported. Never creates a category. Dry run
      # unless apply is true.
      class AddAliases
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(label:, names: nil, min_count: 1, apply: false)
          new(label: label, names: names, min_count: min_count, apply: apply).call
        end

        def initialize(label:, names:, min_count:, apply:)
          @label = label
          @names = names&.map { |name| name.to_s.strip.downcase }&.reject(&:empty?)
          @min_count = min_count.to_i
          @apply = apply
        end

        def call
          added = []
          skipped = []
          matcher = ::Services::Books::GoodreadsEnrichment::GenreMatcher.new
          taken = Set.new

          Report.call(label: @label, unlisted_limit: nil).data[:unlisted_genres].each do |suggestion|
            next unless suggestion[:genre_id]
            next if suggestion[:count] < @min_count
            next if @names && !@names.include?(suggestion[:name])

            name = suggestion[:name]
            found = matcher.match(name)
            if found && (found.genre? || found.audience?)
              skipped << {name: name, reason: "already matches #{found.name}"}
              next
            end
            if taken.include?(name)
              skipped << {name: name, reason: "already suggested for another genre in this run"}
              next
            end

            genre = ::Books::Category.active.where(category_type: %w[genre audience]).find_by(id: suggestion[:genre_id])
            next unless genre

            taken << name
            if @apply
              genre.alternative_names = (Array(genre.alternative_names) + [suggestion[:display].presence || name]).uniq
              genre.save!
            end
            added << {name: suggestion[:display].presence || name, genre: genre.name}
          end

          Result.new(success?: true, errors: [], data: {added: added, skipped: skipped})
        end
      end
    end
  end
end
