module Services
  module Books
    module Profiles
      # A reader's favourite genres and subjects, taken from the recommendation
      # engine's taste profile so the profile page and the recommendations
      # never disagree about what the reader likes. The profile is built the way
      # Recommendations::Engine#build_profile builds it. Below MIN_BOOKS
      # finished or rated books the numbers are noise, so nothing is built.
      class Taste
        MIN_BOOKS = 10
        MAX_GENRES = 5
        MAX_SUBJECTS = 8
        QUALIFYING_KINDS = %i[favorite read].freeze

        # genres: [[Category, Float 0.0..1.0]] strongest first, scaled so the first is 1.0
        # subjects: [Category] strongest first
        Data = Struct.new(:ready, :qualifying_count, :genres, :subjects, keyword_init: true)

        def self.call(user:)
          new(user: user).call
        end

        def initialize(user:)
          @user = user
        end

        def call
          config = Recommendations::Config.resolve
          adapter = Recommendations::Books::Adapter.new(config: config)
          interactions = adapter.interactions(@user)
          qualifying = interactions.count { |i| QUALIFYING_KINDS.include?(i.kind) || !i.rating.nil? }
          return not_ready(qualifying) if qualifying < MIN_BOOKS

          profile = Recommendations::ProfileBuilder.call(
            interactions: interactions,
            categories: adapter.categories_for(interactions.map(&:item_id)),
            catalog_size: adapter.catalog_size,
            type_category_ids: adapter.type_category_ids,
            config: config
          )
          categories = ::Books::Category.active
            .where(id: (profile.genres + profile.subjects).map(&:first)).index_by(&:id)

          genres = scaled(profile.genres.filter_map { |id, w| [categories[id], w] if categories[id] }.first(MAX_GENRES))
          subjects = profile.subjects.filter_map { |id, _| categories[id] }.first(MAX_SUBJECTS)
          return not_ready(qualifying) if genres.empty? && subjects.empty?

          Data.new(ready: true, qualifying_count: qualifying, genres: genres, subjects: subjects)
        end

        private

        def not_ready(qualifying)
          Data.new(ready: false, qualifying_count: qualifying, genres: [], subjects: [])
        end

        def scaled(pairs)
          top = pairs.first&.last.to_f
          return [] unless top.positive?

          pairs.map { |category, weight| [category, weight / top] }
        end
      end
    end
  end
end
